import Foundation

/// JS source for the in-page actuator (`window.__nexAct`). Injected at
/// document-start into the main frame only. Provides the shared
/// selector parser plus DOM lookup primitives that every CLI verb
/// (`nex web click`, `nex web type`, `nex web wait`, ...) and the
/// rebuilt `nex web exec` compose on top of.
///
/// Current surface: selector parsing + `find` / `findAll`. Action
/// verbs (click, type), read verbs (text, attr, count, exists, dom),
/// wait, and long-tail (select, scroll, hover, key) will extend the
/// same namespace.
///
/// Selector forms (single CLI flag, three explicit forms + auto-detect):
///   css:<sel>                        document.querySelector(sel)
///   text:<exact>                     first elem whose trimmed textContent === <exact>
///   text:/<pattern>/<flags>          first elem whose trimmed textContent matches regex
///   role:<role>                      first elem with matching ARIA role
///   role:<role>:name=<name>          + matching accessible name
///   bare ('.foo', '#id', '[x]', ...) auto: CSS if starts with . # [ > * :, else text:
///
/// Idempotency: `window.__nexAct` is defined once. A second injection
/// (e.g. cross-origin navigation that re-runs document-start scripts)
/// is a no-op so any in-flight wait handles survive.
enum WebPaneActuatorScript {
    static let source: String = """
    (function() {
        if (window.__nexAct) { return; }

        // ---- selector parser --------------------------------------

        // Auto-detect heuristic: if the first non-space char is one of
        // these, treat the whole string as CSS. Otherwise fall back to
        // exact-text matching. Keeps the common case ('Add to order')
        // terse without ambiguity for class/id/attribute selectors.
        var CSS_LEAD_RE = /^[.#\\[>*:]/;

        function parseSelector(raw) {
            if (raw == null) {
                return { kind: 'invalid', reason: 'selector is null' };
            }
            // Trim leading whitespace so auto-detect sees the first
            // meaningful char (' .foo' should still route to CSS) and
            // mistyped prefixes ('  css:body') still match. Trailing
            // whitespace is preserved — it may be meaningful inside a
            // text: value or CSS attribute selector.
            var s = String(raw).replace(/^\\s+/, '');
            if (s.length === 0) {
                return { kind: 'invalid', reason: 'selector is empty' };
            }
            // Explicit prefixes win over auto-detect so a literal
            // 'css:' / 'text:' / 'role:' in a class name etc. is
            // still reachable via 'text:css:foo'.
            if (s.indexOf('css:') === 0) {
                return { kind: 'css', selector: s.slice(4) };
            }
            if (s.indexOf('text:') === 0) {
                var rest = s.slice(5);
                // text:/<pattern>/<flags> -> regex form
                if (rest.length > 1 && rest.charAt(0) === '/') {
                    var close = rest.lastIndexOf('/');
                    if (close > 0) {
                        var pattern = rest.slice(1, close);
                        var flags = rest.slice(close + 1);
                        try {
                            return { kind: 'text-regex', regex: new RegExp(pattern, flags) };
                        } catch (e) {
                            return { kind: 'invalid', reason: 'bad regex: ' + e.message };
                        }
                    }
                }
                return { kind: 'text', value: rest };
            }
            if (s.indexOf('role:') === 0) {
                var body = s.slice(5);
                // role:<role>[:name=<name>]
                var nameIdx = body.indexOf(':name=');
                if (nameIdx >= 0) {
                    return {
                        kind: 'role',
                        role: body.slice(0, nameIdx),
                        name: body.slice(nameIdx + ':name='.length)
                    };
                }
                return { kind: 'role', role: body, name: null };
            }
            // Auto-detect: CSS-leading chars route to CSS, otherwise text.
            if (CSS_LEAD_RE.test(s)) {
                return { kind: 'css', selector: s };
            }
            return { kind: 'text', value: s };
        }

        // ---- text + role helpers -----------------------------------

        function trimText(el) {
            var t = el && el.textContent;
            return t == null ? '' : String(t).trim();
        }

        // Skip <script>, <style>, <template> subtrees so their text
        // doesn't pollute matches.
        function shouldSkip(el) {
            var tag = el.tagName;
            return tag === 'SCRIPT' || tag === 'STYLE' || tag === 'TEMPLATE';
        }

        // Whether `el` has a descendant element that also satisfies
        // `predicate`. Used to filter text matches down to the
        // smallest enclosing element — `<html>` and `<body>` both
        // have textContent "Submit" when the page contains a single
        // `<button>Submit</button>`, but agents want the button.
        function hasMatchingDescendant(el, predicate) {
            var kids = el.children;
            for (var i = 0; i < kids.length; i++) {
                var child = kids[i];
                if (shouldSkip(child)) continue;
                if (predicate(child)) return true;
                if (hasMatchingDescendant(child, predicate)) return true;
            }
            return false;
        }

        // TreeWalker scoped to `root` (default: document) that yields
        // the smallest enclosing elements matching `predicate` —
        // skipping any element whose descendants also match, the
        // "smallest enclosing element" rule borrowed from Playwright.
        function smallestEnclosingWalker(root, predicate) {
            return document.createTreeWalker(
                root || document,
                NodeFilter.SHOW_ELEMENT,
                {
                    acceptNode: function(node) {
                        if (shouldSkip(node)) return NodeFilter.FILTER_REJECT;
                        if (!predicate(node)) return NodeFilter.FILTER_SKIP;
                        return hasMatchingDescendant(node, predicate)
                            ? NodeFilter.FILTER_SKIP
                            : NodeFilter.FILTER_ACCEPT;
                    }
                }
            );
        }

        function findFirst(root, predicate) {
            return smallestEnclosingWalker(root, predicate).nextNode();
        }

        function findAllMatches(root, predicate) {
            var walker = smallestEnclosingWalker(root, predicate);
            var out = [];
            var n;
            while ((n = walker.nextNode())) out.push(n);
            return out;
        }

        // Element's accessible name. Falls back through the common
        // sources: aria-label, aria-labelledby, <label for=>, alt,
        // title, then trimmed textContent. Not a full AccName algorithm
        // (no shadow DOM walking, no element-id lookups beyond ids),
        // but covers the patterns agents reach for in practice.
        function accessibleName(el) {
            if (!el) return '';
            var aria = el.getAttribute && el.getAttribute('aria-label');
            if (aria) return aria.trim();
            var labelledby = el.getAttribute && el.getAttribute('aria-labelledby');
            if (labelledby) {
                var ids = labelledby.split(/\\s+/);
                var parts = [];
                for (var i = 0; i < ids.length; i++) {
                    var ref = document.getElementById(ids[i]);
                    if (ref) parts.push(trimText(ref));
                }
                var joined = parts.join(' ').trim();
                if (joined) return joined;
            }
            if (el.id) {
                var labelEl = document.querySelector('label[for="' + cssEscape(el.id) + '"]');
                if (labelEl) {
                    var lt = trimText(labelEl);
                    if (lt) return lt;
                }
            }
            var alt = el.getAttribute && el.getAttribute('alt');
            if (alt) return alt.trim();
            var title = el.getAttribute && el.getAttribute('title');
            if (title) return title.trim();
            return trimText(el);
        }

        // CSS.escape polyfill (Safari has it but be defensive — older
        // WebKit builds shipped without it on some platforms).
        function cssEscape(s) {
            if (window.CSS && typeof window.CSS.escape === 'function') {
                return window.CSS.escape(s);
            }
            return String(s).replace(/[^a-zA-Z0-9_-]/g, function(c) {
                return '\\\\' + c;
            });
        }

        // Map a parsed selector to a DOM-level predicate / direct
        // querySelector for css. Returns one of:
        //   { fn: function(root) -> Element|null, kind: <string> }
        //   { fnAll: function(root) -> Element[], kind: <string> }
        //   { error: <string> }
        function compile(parsed) {
            if (parsed.kind === 'invalid') return { error: parsed.reason };
            if (parsed.kind === 'css') {
                return {
                    kind: 'css',
                    fn: function(root) {
                        try {
                            return (root || document).querySelector(parsed.selector);
                        } catch (e) {
                            return null;
                        }
                    },
                    fnAll: function(root) {
                        try {
                            return Array.prototype.slice.call(
                                (root || document).querySelectorAll(parsed.selector)
                            );
                        } catch (e) {
                            return [];
                        }
                    }
                };
            }
            if (parsed.kind === 'text') {
                var target = parsed.value;
                var pred = function(el) {
                    return trimText(el) === target;
                };
                return {
                    kind: 'text',
                    fn: function(root) { return findFirst(root, pred); },
                    fnAll: function(root) { return findAllMatches(root, pred); }
                };
            }
            if (parsed.kind === 'text-regex') {
                var re = parsed.regex;
                // Reset lastIndex before every test — with /g or /y
                // flags `test()` mutates lastIndex and skips alternate
                // candidates on the next call. Cheap, and avoids
                // having to reject stateful flags at parse time.
                var pred2 = function(el) {
                    re.lastIndex = 0;
                    return re.test(trimText(el));
                };
                return {
                    kind: 'text-regex',
                    fn: function(root) { return findFirst(root, pred2); },
                    fnAll: function(root) { return findAllMatches(root, pred2); }
                };
            }
            if (parsed.kind === 'role') {
                var wantRole = parsed.role;
                var wantName = parsed.name; // may be null
                var pred3 = function(el) {
                    var role = el.getAttribute && el.getAttribute('role');
                    if (!role) role = implicitRole(el);
                    if (role !== wantRole) return false;
                    if (wantName == null) return true;
                    return accessibleName(el) === wantName;
                };
                return {
                    kind: 'role',
                    fn: function(root) { return findFirst(root, pred3); },
                    fnAll: function(root) { return findAllMatches(root, pred3); }
                };
            }
            return { error: 'unknown selector kind: ' + parsed.kind };
        }

        // Minimal implicit-role map. Covers the elements agents
        // actually target via role:. Not a full ARIA mapping — that
        // would need to consider input[type], <header> inside <main>,
        // etc. If pages need exotic roles, set role= explicitly.
        function implicitRole(el) {
            var tag = el.tagName;
            switch (tag) {
                case 'A': return el.hasAttribute('href') ? 'link' : null;
                case 'BUTTON': return 'button';
                case 'NAV': return 'navigation';
                case 'MAIN': return 'main';
                case 'HEADER': return 'banner';
                case 'FOOTER': return 'contentinfo';
                case 'ASIDE': return 'complementary';
                case 'ARTICLE': return 'article';
                case 'SECTION': return 'region';
                case 'DIALOG': return 'dialog';
                case 'TEXTAREA': return 'textbox';
                case 'SELECT': return el.multiple ? 'listbox' : 'combobox';
            }
            if (tag === 'INPUT') {
                var type = (el.getAttribute('type') || 'text').toLowerCase();
                // Allowlist-only. Defaulting to 'textbox' for any
                // unhandled type would match <input type=hidden> (a
                // common CSRF token pattern that precedes the visible
                // textbox), <input type=password> (intentionally not
                // exposed as textbox by ARIA), and <input type=color>
                // / <input type=date> (no clean ARIA mapping). Force
                // explicit role= for those.
                switch (type) {
                    case 'button': case 'submit': case 'reset': case 'image':
                    case 'file':
                        return 'button';
                    case 'checkbox': return 'checkbox';
                    case 'radio': return 'radio';
                    case 'range': return 'slider';
                    case 'search': return 'searchbox';
                    case 'number': return 'spinbutton';
                    case 'text': case 'email': case 'tel': case 'url':
                        return 'textbox';
                    default: return null;
                }
            }
            return null;
        }

        // ---- click + type primitives -------------------------------

        // Synthesise a full pointer-down → mouse-down → pointer-up →
        // mouse-up → click sequence. Calling .click() alone misses
        // libraries that listen for pointer / mouse events (react-dnd,
        // framer-motion, custom dropdowns), so we always dispatch the
        // full envelope. .click() runs last because most click handlers
        // listen for it, not for pointerup.
        function dispatchClickSequence(target, opts) {
            opts = opts || {};
            var rect = target.getBoundingClientRect();
            // `at: [x, y]` (offsets within the element) is useful for
            // canvas-driven UIs. Default to the centre so synthesised
            // coordinates land somewhere the element actually accepts.
            var localX = (opts.at && typeof opts.at.x === 'number') ? opts.at.x : rect.width / 2;
            var localY = (opts.at && typeof opts.at.y === 'number') ? opts.at.y : rect.height / 2;
            var clientX = rect.left + localX;
            var clientY = rect.top + localY;
            var button = opts.right ? 2 : 0;
            var common = {
                bubbles: true, cancelable: true, composed: true,
                clientX: clientX, clientY: clientY, button: button, buttons: 1
            };
            // Older WebKit builds lack the PointerEvent constructor;
            // skip the pointer event but still send the mouse event.
            function tryPointer(name) {
                try { target.dispatchEvent(new PointerEvent(name, common)); }
                catch (e) {}
            }
            tryPointer('pointerdown');
            target.dispatchEvent(new MouseEvent('mousedown', common));
            tryPointer('pointerup');
            target.dispatchEvent(new MouseEvent('mouseup', common));
            if (opts.right) {
                target.dispatchEvent(new MouseEvent('contextmenu', common));
            } else if (opts.at) {
                // .click() dispatches a click event but strips the
                // clientX/Y we synthesised, which breaks canvas /
                // custom-control listeners that read coordinates.
                // When the caller asked for a specific point, fire a
                // synthesised click carrying it. Trade-off: native
                // form-submit / anchor-follow semantics that rely on
                // trusted events won't fire for this path.
                target.dispatchEvent(new MouseEvent('click', common));
                if (opts.double) {
                    target.dispatchEvent(new MouseEvent('dblclick', common));
                }
            } else {
                // .click() respects disabled state and form/anchor
                // semantics that synthesised events skip.
                if (typeof target.click === 'function') {
                    target.click();
                }
                if (opts.double) {
                    target.dispatchEvent(new MouseEvent('dblclick', common));
                }
            }
        }

        function click(selector, opts) {
            var el = find(selector);
            if (!el) {
                return { ok: false, error: 'no match for selector: ' + String(selector) };
            }
            try {
                dispatchClickSequence(el, opts || {});
            } catch (e) {
                return {
                    ok: false,
                    error: 'click dispatch failed: ' + (e && e.message ? e.message : String(e))
                };
            }
            return { ok: true, matched: true, text: trimText(el) };
        }

        // The prototype `value` setter, which React / Vue / Svelte
        // controlled inputs honour even when the framework has shadowed
        // the instance setter with one that ignores writes.
        function nativeSetter(el) {
            var proto;
            if (el instanceof HTMLTextAreaElement) {
                proto = HTMLTextAreaElement.prototype;
            } else if (el instanceof HTMLSelectElement) {
                proto = HTMLSelectElement.prototype;
            } else {
                proto = HTMLInputElement.prototype;
            }
            var desc = Object.getOwnPropertyDescriptor(proto, 'value');
            return (desc && desc.set) ? desc.set : null;
        }

        function setValue(el, value) {
            var setter = nativeSetter(el);
            if (setter) {
                setter.call(el, value);
            } else {
                el.value = value;
            }
        }

        function isTypable(el) {
            if (!el) return false;
            if (el.isContentEditable) return true;
            var tag = el.tagName;
            if (tag === 'TEXTAREA') return true;
            if (tag === 'INPUT') {
                var type = (el.getAttribute('type') || 'text').toLowerCase();
                // type=button/submit/reset/checkbox/radio/file etc. are
                // not typable. Whitelist the text-shaped ones.
                return [
                    'text', 'search', 'email', 'tel', 'url', 'password',
                    'number', 'date', 'datetime-local', 'time', 'month', 'week'
                ].indexOf(type) >= 0;
            }
            return false;
        }

        // `keypress` is deprecated and ignored by modern frameworks,
        // so we only fire keydown + keyup. Matches Playwright.
        function dispatchKey(target, name, opts) {
            var keyOpts = Object.assign({
                bubbles: true, cancelable: true, composed: true
            }, opts || {});
            keyOpts.key = name;
            target.dispatchEvent(new KeyboardEvent('keydown', keyOpts));
            target.dispatchEvent(new KeyboardEvent('keyup', keyOpts));
        }

        function type(selector, text, opts) {
            opts = opts || {};
            var el = find(selector);
            if (!el) {
                return { ok: false, error: 'no match for selector: ' + String(selector) };
            }
            if (!isTypable(el)) {
                return {
                    ok: false,
                    error: 'element is not typable (tag=' + el.tagName + ', type=' +
                        (el.getAttribute && el.getAttribute('type')) + ')'
                };
            }
            try {
                // Focus first so onFocus handlers run before value
                // mutations; some controlled inputs gate `onChange`
                // dispatch on document.activeElement matching.
                if (typeof el.focus === 'function') el.focus();
            } catch (e) { /* focus on unfocusable element — ignore */ }

            // contentEditable path: set textContent + input event.
            if (el.isContentEditable) {
                var existing = opts.replace === false ? (el.textContent || '') : '';
                el.textContent = existing + String(text);
                el.dispatchEvent(new InputEvent('input', { bubbles: true }));
                if (opts.submit) {
                    dispatchKey(el, 'Enter');
                }
                return { ok: true, value: el.textContent };
            }

            var prev = el.value || '';
            var next;
            if (opts.replace === false) {
                next = prev + String(text);
            } else {
                next = String(text);
            }
            setValue(el, next);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            if (opts.submit) {
                // Two paths: the explicit Enter keystroke covers
                // search inputs + non-form widgets that listen for
                // keydown; form.requestSubmit() covers actual <form>s
                // whose submit button is disabled until requestSubmit
                // walks form validation.
                dispatchKey(el, 'Enter');
                var form = el.form;
                if (form && typeof form.requestSubmit === 'function') {
                    try { form.requestSubmit(); } catch (e) { /* submit blocked — ignore */ }
                }
            }
            return { ok: true, value: el.value };
        }

        // ---- public API --------------------------------------------

        function find(selector) {
            var parsed = parseSelector(selector);
            var compiled = compile(parsed);
            if (compiled.error) return null;
            return compiled.fn(document) || null;
        }

        function findAll(selector) {
            var parsed = parseSelector(selector);
            var compiled = compile(parsed);
            if (compiled.error) return [];
            return compiled.fnAll(document);
        }

        window.__nexAct = {
            find: find,
            findAll: findAll,
            click: click,
            type: type,

            // Exposed for unit tests + future phases. Underscore-prefixed
            // to signal "subject to change"; CLI verbs go through the
            // public methods.
            _parseSelector: parseSelector,
            _compile: compile,
            _accessibleName: accessibleName,
            _implicitRole: implicitRole
        };
    })();
    """
}
