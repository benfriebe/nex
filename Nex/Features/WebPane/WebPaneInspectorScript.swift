import Foundation

/// JS source for the element-picker overlay used by `nex web inspect`.
/// Injected at document-start into the main frame only. Two global
/// hooks are exposed:
///
/// - `__nexInspectorEnable(nonce)` — arm the picker; the next click
///   serialises the clicked element and posts to the `nexInspect`
///   native handler with the nonce so spoofed messages from page
///   JS are rejected by the Swift side.
/// - `__nexInspectorDisable()` — symmetric tear-down. Removes the
///   overlay, restores the cursor, and detaches event listeners.
///
/// Arming is single-shot: the click handler calls `disable()` after
/// posting so the inspector can't leak into the next click cycle.
enum WebPaneInspectorScript {
    static let source: String = """
    (function() {
        if (window.__nexInspectorInstalled) { return; }
        window.__nexInspectorInstalled = true;

        var bridge = (window.webkit && window.webkit.messageHandlers &&
                      window.webkit.messageHandlers.nexInspect);

        var state = {
            armed: false,
            sticky: false,
            nonce: null,
            overlay: null,
            previousCursor: null,
            onMove: null,
            onClick: null,
            onKey: null
        };

        function ensureOverlay() {
            if (state.overlay) return state.overlay;
            var div = document.createElement('div');
            div.setAttribute('data-nex-overlay', '1');
            div.style.cssText = [
                'position:fixed', 'pointer-events:none', 'z-index:2147483647',
                'border:2px solid #007AFF', 'background:rgba(0,122,255,0.18)',
                'border-radius:2px', 'box-sizing:border-box',
                'transition:left 60ms linear, top 60ms linear, width 60ms linear, height 60ms linear',
                'display:none'
            ].join(';');
            (document.body || document.documentElement).appendChild(div);
            state.overlay = div;
            return div;
        }

        function moveOverlay(rect) {
            var o = ensureOverlay();
            o.style.display = 'block';
            o.style.left = rect.left + 'px';
            o.style.top = rect.top + 'px';
            o.style.width = rect.width + 'px';
            o.style.height = rect.height + 'px';
        }

        function hideOverlay() {
            if (state.overlay) state.overlay.style.display = 'none';
        }

        function elementAt(x, y) {
            var el = document.elementFromPoint(x, y);
            // Walk up through pointer-events:none overlays our own
            // overlay is hidden during elementFromPoint via z-index/
            // pointer-events, but just in case.
            while (el && el.hasAttribute && el.hasAttribute('data-nex-overlay')) {
                el = el.parentElement;
            }
            return el;
        }

        /// True when `node` (or any ancestor) is part of Nex's own
        /// overlay surface — picker overlay, batch marker container,
        /// numbered badge, focus ring, or comment popover. Clicks on
        /// these shouldn't capture another element into the batch,
        /// and hover-tracking shouldn't outline them either.
        function isOurOverlay(node) {
            while (node) {
                if (node.nodeType === 1 && node.hasAttribute) {
                    if (node.hasAttribute('data-nex-overlay') ||
                        node.hasAttribute('data-nex-batch-marker') ||
                        node.hasAttribute('data-nex-batch-markers') ||
                        node.hasAttribute('data-nex-batch-popover') ||
                        node.hasAttribute('data-nex-batch-focus-ring')) {
                        return true;
                    }
                }
                node = node.parentNode;
                if (node === document.body || node === document.documentElement) break;
            }
            return false;
        }

        function getXPath(el) {
            if (!el) return '';
            if (el.id) return '//*[@id=' + JSON.stringify(el.id) + ']';
            var parts = [];
            var node = el;
            while (node && node.nodeType === 1 && node !== document.documentElement) {
                var ix = 1;
                var sib = node.previousSibling;
                while (sib) {
                    if (sib.nodeType === 1 && sib.tagName === node.tagName) ix++;
                    sib = sib.previousSibling;
                }
                parts.unshift(node.tagName.toLowerCase() + '[' + ix + ']');
                node = node.parentElement;
            }
            return '/html/' + parts.join('/');
        }

        function escapeCSS(s) {
            try { return CSS.escape(s); }
            catch (e) { return s.replace(/[^A-Za-z0-9_-]/g, '\\\\$&'); }
        }

        function getCSSSelector(el) {
            if (!el) return '';
            // Prefer stable identifiers in priority order: id,
            // data-testid, data-test, name. Falls back to a chained
            // tag>tag selector when none are present.
            if (el.id) return '#' + escapeCSS(el.id);
            var testid = el.getAttribute && (el.getAttribute('data-testid') ||
                                             el.getAttribute('data-test'));
            if (testid) return '[data-testid=' + JSON.stringify(testid) + ']';
            var name = el.getAttribute && el.getAttribute('name');
            if (name && el.tagName) {
                return el.tagName.toLowerCase() + '[name=' + JSON.stringify(name) + ']';
            }
            var parts = [];
            var node = el;
            while (node && node.nodeType === 1 && parts.length < 6 && node !== document.documentElement) {
                var part = node.tagName.toLowerCase();
                if (node.id) { parts.unshift(part + '#' + escapeCSS(node.id)); break; }
                var classes = (node.getAttribute('class') || '').trim().split(/\\s+/).filter(Boolean);
                if (classes.length) part += '.' + classes.slice(0, 2).map(escapeCSS).join('.');
                var idx = 1, sib = node.previousElementSibling;
                while (sib) {
                    if (sib.tagName === node.tagName) idx++;
                    sib = sib.previousElementSibling;
                }
                part += ':nth-of-type(' + idx + ')';
                parts.unshift(part);
                node = node.parentElement;
            }
            return parts.join(' > ');
        }

        function attributesOf(el) {
            var out = {};
            if (!el || !el.attributes) return out;
            for (var i = 0; i < el.attributes.length; i++) {
                var a = el.attributes[i];
                out[a.name] = a.value;
            }
            return out;
        }

        function surroundingText(el) {
            try {
                var t = (el && el.textContent) ? el.textContent.trim() : '';
                if (t.length <= 200) return t;
                return t.slice(0, 200) + '…';
            } catch (e) { return ''; }
        }

        function contextHTML(el) {
            try {
                var parent = el && el.parentElement;
                if (!parent) return '';
                var html = parent.outerHTML || '';
                if (html.length <= 4096) return html;
                return html.slice(0, 4096);
            } catch (e) { return ''; }
        }

        function capture(el) {
            if (!el) return null;
            var rect = el.getBoundingClientRect();
            return {
                nonce: state.nonce,
                selector: getCSSSelector(el),
                xpath: getXPath(el),
                tag: (el.tagName || '').toLowerCase(),
                element_id: el.id || '',
                outer_html: el.outerHTML || '',
                attributes: attributesOf(el),
                rect: {
                    x: rect.left, y: rect.top,
                    w: rect.width, h: rect.height
                },
                text: surroundingText(el),
                context_html: contextHTML(el),
                url: location.href,
                captured_at: new Date().toISOString()
            };
        }

        function onMove(ev) {
            if (!state.armed) return;
            // While the batch comment popover is open, suspend the
            // hover outline entirely — the user is authoring a
            // comment, not picking. They Done/Remove first.
            if (window.__nexBatchHasOpenPopover) {
                hideOverlay();
                return;
            }
            var el = ev.target;
            if (!el || el === state.overlay) return;
            // Don't outline our own overlay surfaces (numbered badges,
            // comment popover, focus ring) when hovered — they aren't
            // valid pick targets.
            if (isOurOverlay(el)) {
                hideOverlay();
                return;
            }
            var rect = el.getBoundingClientRect();
            moveOverlay({
                left: rect.left, top: rect.top,
                width: rect.width, height: rect.height
            });
        }

        function onClick(ev) {
            if (!state.armed) return;
            // Clicks that land on our own overlay surface — a badge,
            // the comment popover, the focus ring — should NOT be
            // treated as new picks. Let the event pass through to its
            // normal handlers (badge click → focuses that marker;
            // popover textarea → text input).
            if (isOurOverlay(ev.target)) return;
            // Comment popover is open — the user has unfinished
            // business with the current item. Don't create another
            // pick until they hit Done or Remove. Let the click
            // through to the page (no preventDefault) so existing
            // page interaction isn't blocked either.
            if (window.__nexBatchHasOpenPopover) return;
            ev.preventDefault();
            ev.stopPropagation();
            ev.stopImmediatePropagation();
            var payload = capture(ev.target);
            if (payload && bridge) {
                try { bridge.postMessage(payload); } catch (e) {}
            }
            // In sticky mode the picker stays armed for the next
            // click — batch annotation uses this to collect several
            // elements without round-tripping through Swift for
            // re-arm. Single-shot mode (default) disables here.
            if (!state.sticky) {
                disable();
            }
        }

        function onKey(ev) {
            if (state.armed && ev.key === 'Escape') {
                // While the batch popover is open, Esc belongs to the
                // popover (its textarea handler dismisses just that
                // popover so the user can pick the next element).
                // Without this skip, the capture-phase listener here
                // wins the event before it reaches the textarea and
                // disarms the whole batch instead.
                if (window.__nexBatchHasOpenPopover) return;
                ev.preventDefault();
                ev.stopPropagation();
                // Snapshot the nonce BEFORE disable() — it clears
                // state.nonce, and the Swift coordinator drops any
                // cancel message whose nonce doesn't match the
                // currently-armed one. Without this capture the JS
                // disarms but the Swift-side picker stays armed.
                var nonceAtCancel = state.nonce;
                disable();
                try { bridge && bridge.postMessage({ nonce: nonceAtCancel, cancelled: true }); }
                catch (e) {}
            }
        }

        function enable(nonce, sticky) {
            if (state.armed) disable();
            state.armed = true;
            state.sticky = sticky === true;
            state.nonce = String(nonce || '');
            state.previousCursor = document.documentElement.style.cursor;
            document.documentElement.style.cursor = 'crosshair';

            state.onMove = onMove;
            state.onClick = onClick;
            state.onKey = onKey;
            // Use capture so we win against page-level handlers.
            document.addEventListener('mousemove', state.onMove, true);
            document.addEventListener('click', state.onClick, true);
            document.addEventListener('keydown', state.onKey, true);
        }

        function disable() {
            if (!state.armed) return;
            state.armed = false;
            state.sticky = false;
            state.nonce = null;
            document.documentElement.style.cursor = state.previousCursor || '';
            state.previousCursor = null;
            hideOverlay();
            if (state.onMove) document.removeEventListener('mousemove', state.onMove, true);
            if (state.onClick) document.removeEventListener('click', state.onClick, true);
            if (state.onKey) document.removeEventListener('keydown', state.onKey, true);
            state.onMove = state.onClick = state.onKey = null;
        }

        window.__nexInspectorEnable = enable;
        window.__nexInspectorDisable = disable;
    })();
    """
}
