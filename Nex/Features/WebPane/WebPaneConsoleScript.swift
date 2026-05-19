import Foundation

/// JS source injected into every WKWebView under a Nex web pane.
/// Wraps the standard console methods + window error events, posting
/// a structured record back to the native `nexConsole` script handler.
///
/// The wrapper is idempotent: it stashes the originals under
/// `__nexConsoleOriginals` and bails on re-injection so two
/// document-start firings (e.g. cross-origin iframe → main frame
/// navigation) don't double up captured lines.
///
/// Serialisation: each argument is run through `JSON.stringify` with
/// a fallback to `String(arg)` for cyclic / unserialisable values
/// (DOM nodes, Errors, etc.). The native handler receives a single
/// `message` string per call so the buffer doesn't need to know
/// about argument boundaries.
enum WebPaneConsoleScript {
    static let source: String = """
    (function() {
        if (window.__nexConsoleInstalled) { return; }
        window.__nexConsoleInstalled = true;

        var bridge = (window.webkit && window.webkit.messageHandlers &&
                      window.webkit.messageHandlers.nexConsole);
        if (!bridge) { return; }

        function safeString(v) {
            try {
                if (v === undefined) return 'undefined';
                if (v === null) return 'null';
                if (typeof v === 'string') return v;
                if (typeof v === 'function') return v.toString();
                if (v instanceof Error) return (v.stack || (v.name + ': ' + v.message));
                var seen = new WeakSet();
                return JSON.stringify(v, function(k, val) {
                    if (typeof val === 'object' && val !== null) {
                        if (seen.has(val)) return '[Circular]';
                        seen.add(val);
                    }
                    return val;
                });
            } catch (e) {
                try { return String(v); } catch (e2) { return '[Unserialisable]'; }
            }
        }

        function joinArgs(args) {
            var parts = [];
            for (var i = 0; i < args.length; i++) {
                parts.push(safeString(args[i]));
            }
            return parts.join(' ');
        }

        // Some WebKit builds make `console.error` (and occasionally
        // other methods) a non-writable own property of `console`,
        // so a plain `console.error = ...` assignment silently
        // no-ops and the wrapper never runs. Use defineProperty
        // with writable+configurable so the override sticks
        // regardless of the original descriptor.
        var levels = ['log', 'debug', 'info', 'warn', 'error'];
        window.__nexConsoleOriginals = {};
        for (var i = 0; i < levels.length; i++) {
            (function(level) {
                var original = console[level] ? console[level].bind(console) : null;
                window.__nexConsoleOriginals[level] = original;
                var wrapped = function() {
                    try {
                        bridge.postMessage({
                            level: level,
                            message: joinArgs(arguments),
                            url: location.href
                        });
                    } catch (postErr) { /* swallow — never break the page */ }
                    if (original) { try { original.apply(console, arguments); } catch (e) {} }
                };
                try {
                    Object.defineProperty(console, level, {
                        value: wrapped,
                        writable: true,
                        configurable: true
                    });
                } catch (defineErr) {
                    // Last-resort fallback: plain assignment. Some
                    // hardened consoles disallow defineProperty too,
                    // in which case neither approach works and we
                    // just lose this level.
                    try { console[level] = wrapped; } catch (assignErr) {}
                }
            })(levels[i]);
        }

        // `console.exception` and `console.assert(false, ...)` are
        // alternate paths some libraries use for error reporting;
        // route them through the same channel at level=error so
        // callers don't have to know which one fired.
        try {
            var origException = console.exception;
            Object.defineProperty(console, 'exception', {
                value: function() {
                    try {
                        bridge.postMessage({
                            level: 'error',
                            message: joinArgs(arguments),
                            url: location.href
                        });
                    } catch (e) {}
                    if (origException) { try { origException.apply(console, arguments); } catch (e) {} }
                },
                writable: true, configurable: true
            });
        } catch (e) {}

        try {
            var origAssert = console.assert;
            Object.defineProperty(console, 'assert', {
                value: function(condition) {
                    if (!condition) {
                        var rest = Array.prototype.slice.call(arguments, 1);
                        try {
                            bridge.postMessage({
                                level: 'error',
                                message: 'Assertion failed: ' + joinArgs(rest),
                                url: location.href
                            });
                        } catch (e) {}
                    }
                    if (origAssert) { try { origAssert.apply(console, arguments); } catch (e) {} }
                },
                writable: true, configurable: true
            });
        } catch (e) {}

        // Uncaught errors. Hook both `window.onerror` and the
        // addEventListener channel — different page configurations
        // surface errors through one or the other (older pages with
        // `window.onerror = ...` would shadow our addEventListener
        // listener otherwise). Capture phase gives us the event
        // before any page-level handler can call preventDefault.
        function reportPageError(message, source, lineno, colno, error) {
            try {
                var msgParts = [];
                if (error && error.stack) {
                    msgParts.push(error.stack);
                } else if (message) {
                    msgParts.push(String(message));
                }
                if (source) {
                    msgParts.push('(' + source + ':' + (lineno || 0) + ':' + (colno || 0) + ')');
                }
                bridge.postMessage({
                    level: 'error',
                    message: msgParts.join(' ') || 'Script error',
                    url: location.href,
                    lineNumber: lineno || null,
                    columnNumber: colno || null
                });
            } catch (e) {}
        }

        window.addEventListener('error', function(ev) {
            reportPageError(
                ev.message, ev.filename, ev.lineno, ev.colno, ev.error
            );
        }, true);

        var prevOnError = window.onerror;
        window.onerror = function(msg, src, lineno, colno, error) {
            reportPageError(msg, src, lineno, colno, error);
            if (typeof prevOnError === 'function') {
                try { return prevOnError.apply(this, arguments); } catch (e) {}
            }
            // Return false so the browser still surfaces the error
            // to the Inspector / page handler chain.
            return false;
        };

        window.addEventListener('unhandledrejection', function(ev) {
            var reason = ev && ev.reason;
            try {
                bridge.postMessage({
                    level: 'error',
                    message: 'Unhandled promise rejection: ' + safeString(reason),
                    url: location.href
                });
            } catch (e) {}
        }, true);

        // Subresource load failures (<img>, <script>, <link>, <video>,
        // <audio>, <iframe>). The `error` event fires on the element
        // itself and does not bubble, but it does propagate through
        // the capture phase — listening at `window` with `capture:true`
        // is the standard pattern. The `ev.target !== window` guard
        // distinguishes these from script-level errors which are
        // already handled by the regular `error` listener above.
        window.addEventListener('error', function(ev) {
            var target = ev.target;
            if (!target || target === window) return;
            try {
                var tag = (target.tagName || '').toLowerCase();
                var src = target.src || target.href || target.currentSrc || '';
                bridge.postMessage({
                    level: 'error',
                    message: 'resource load failed: <' + tag + '> ' + src,
                    url: location.href
                });
            } catch (e) {}
        }, true);

        // Content Security Policy violations.
        window.addEventListener('securitypolicyviolation', function(ev) {
            try {
                bridge.postMessage({
                    level: 'error',
                    message: 'CSP violation: ' + (ev.violatedDirective || '') +
                        ' — blocked ' + (ev.blockedURI || '') +
                        ' (effective: ' + (ev.effectiveDirective || '') + ')',
                    url: location.href
                });
            } catch (e) {}
        }, true);

        // Network-level error capture. WebKit emits `Failed to load
        // resource`, CORS errors, and fetch failures to the Inspector
        // directly from its C++ networking stack — those never touch
        // JS console.error, so the wrappers above can't see them.
        // Hook `fetch` and `XMLHttpRequest` instead so any failed
        // request surfaces through the same channel.

        var originalFetch = window.fetch;
        if (typeof originalFetch === 'function') {
            window.fetch = function() {
                var url = '';
                try {
                    var arg = arguments[0];
                    url = (typeof arg === 'string') ? arg : (arg && arg.url) || '';
                } catch (e) {}
                return originalFetch.apply(this, arguments).then(
                    function(response) {
                        try {
                            if (!response.ok) {
                                bridge.postMessage({
                                    level: 'error',
                                    message: 'fetch ' + response.status + ' ' + (response.statusText || '') +
                                        ' — ' + url,
                                    url: location.href
                                });
                            }
                        } catch (e) {}
                        return response;
                    },
                    function(err) {
                        try {
                            bridge.postMessage({
                                level: 'error',
                                message: 'fetch failed — ' + (err && err.message ? err.message : String(err)) +
                                    ' — ' + url,
                                url: location.href
                            });
                        } catch (postErr) {}
                        throw err;
                    }
                );
            };
        }

        try {
            var XHRProto = XMLHttpRequest.prototype;
            var originalOpen = XHRProto.open;
            var originalSend = XHRProto.send;
            XHRProto.open = function(method, requestURL) {
                try { this.__nexMethod = method; this.__nexURL = requestURL; } catch (e) {}
                return originalOpen.apply(this, arguments);
            };
            XHRProto.send = function() {
                var xhr = this;
                function reportFailure(kind, detail) {
                    try {
                        bridge.postMessage({
                            level: 'error',
                            message: 'XHR ' + kind + ' — ' + (xhr.__nexMethod || 'GET') + ' ' +
                                (xhr.__nexURL || '') + (detail ? ' — ' + detail : ''),
                            url: location.href
                        });
                    } catch (e) {}
                }
                xhr.addEventListener('error', function() { reportFailure('error'); });
                xhr.addEventListener('timeout', function() { reportFailure('timeout'); });
                xhr.addEventListener('abort', function() { reportFailure('abort'); });
                xhr.addEventListener('load', function() {
                    if (xhr.status >= 400) {
                        reportFailure(String(xhr.status), xhr.statusText || '');
                    }
                });
                return originalSend.apply(this, arguments);
            };
        } catch (e) {}
    })();
    """
}
