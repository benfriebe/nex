import Foundation

/// JS that overlays numbered badges on every element captured during a
/// batch-annotate session, plus a `nexBatchMarker` bridge for badge
/// clicks and comment edits.
///
/// API exposed on `window`:
/// - `__nexBatchSetMarkers([{id, selector, label, comment}])` — replace
///   the current marker set. Skips entries whose selector no longer
///   resolves.
/// - `__nexBatchUpdateComment(id, comment)` — push an external (panel)
///   comment edit into the page-side popover. No-op if the popover's
///   textarea is currently being typed into (avoids clobbering the
///   user's cursor).
/// - `__nexBatchClearMarkers()` — remove every marker + popover.
/// - `__nexBatchHighlight(id, scrollIntoView)` — focus a marker. Shows
///   the comment popover next to its badge and draws the focus ring.
/// - `__nexBatchUnfocus()` — hide the popover + focus ring.
///
/// Bridge messages:
/// - `{ id }`                              — user clicked a badge.
/// - `{ commentChanged: { id, comment } }` — popover textarea edit.
/// - `{ dismiss: { id } }`                 — Done button / Esc in popover.
/// - `{ remove:  { id } }`                 — Remove button in popover.
enum WebPaneBatchMarkerScript {
    static let source: String = """
    (function() {
        if (window.__nexBatchMarkersInstalled) return;
        window.__nexBatchMarkersInstalled = true;

        var bridge = (window.webkit && window.webkit.messageHandlers &&
                      window.webkit.messageHandlers.nexBatchMarker);

        var markers = {};       // id -> {selector, label, comment, badgeEl}
        var container = null;
        var focusRing = null;
        var focusedID = null;
        /// When `highlight(id)` arrives before `setMarkers` has
        /// included that id, we remember it here and apply on the
        /// next sync. Without this the focus ring gets dropped on
        /// every other pick in batch mode (sync + highlight race).
        var pendingFocusID = null;
        var popover = null;
        var popoverTextarea = null;
        var popoverLabel = null;

        function ensureContainer() {
            if (container) return container;
            container = document.createElement('div');
            container.setAttribute('data-nex-batch-markers', '1');
            container.style.cssText = [
                'position:fixed', 'top:0', 'left:0',
                'width:100%', 'height:100%',
                'pointer-events:none',
                'z-index:2147483646'
            ].join(';');
            (document.body || document.documentElement).appendChild(container);
            return container;
        }

        function clearAll() {
            for (var id in markers) {
                if (markers[id].badgeEl) markers[id].badgeEl.remove();
            }
            markers = {};
            clearFocusRing();
            hidePopover();
            popover = null;
            popoverTextarea = null;
            popoverLabel = null;
            window.__nexBatchHasOpenPopover = false;
            if (container) { container.remove(); container = null; }
        }

        function ensureFocusRing() {
            if (focusRing) return focusRing;
            focusRing = document.createElement('div');
            focusRing.setAttribute('data-nex-batch-focus-ring', '1');
            focusRing.style.cssText = [
                'position:fixed', 'pointer-events:none',
                'z-index:2147483645',
                'border:2px solid #007AFF',
                'border-radius:3px',
                'background:rgba(0,122,255,0.12)',
                'box-shadow:0 0 0 1px rgba(255,255,255,0.6), 0 0 12px rgba(0,122,255,0.5)',
                'box-sizing:border-box',
                'transition:left 80ms linear, top 80ms linear, width 80ms linear, height 80ms linear, opacity 120ms linear',
                'display:none', 'opacity:0'
            ].join(';');
            ensureContainer().appendChild(focusRing);
            return focusRing;
        }

        function clearFocusRing() {
            focusedID = null;
            pendingFocusID = null;
            if (focusRing) {
                focusRing.style.display = 'none';
                focusRing.style.opacity = '0';
            }
        }

        function positionFocusRing() {
            if (!focusedID) return;
            var m = markers[focusedID];
            if (!m) { clearFocusRing(); return; }
            var el = queryElement(m.selector);
            if (!el) { clearFocusRing(); return; }
            var rect = el.getBoundingClientRect();
            var vw = window.innerWidth;
            var vh = window.innerHeight;
            var collapsed = rect.width === 0 && rect.height === 0;
            var offscreen = rect.bottom <= 0 || rect.right <= 0 ||
                            rect.top >= vh || rect.left >= vw;
            if (collapsed || offscreen) {
                if (focusRing) {
                    focusRing.style.display = 'none';
                    focusRing.style.opacity = '0';
                }
                return;
            }
            var ring = ensureFocusRing();
            ring.style.display = 'block';
            ring.style.opacity = '1';
            ring.style.left = (rect.left - 3) + 'px';
            ring.style.top = (rect.top - 3) + 'px';
            ring.style.width = (rect.width + 6) + 'px';
            ring.style.height = (rect.height + 6) + 'px';
        }

        function queryElement(selector) {
            if (!selector) return null;
            try { return document.querySelector(selector); }
            catch (e) { return null; }
        }

        function ensurePopover() {
            if (popover) return popover;
            popover = document.createElement('div');
            popover.setAttribute('data-nex-batch-popover', '1');
            popover.style.cssText = [
                'position:fixed',
                'min-width:200px', 'max-width:260px',
                'background:#1c1c1e', 'color:#fff',
                'border:1px solid rgba(255,255,255,0.18)',
                'border-radius:6px',
                'box-shadow:0 6px 24px rgba(0,0,0,0.4)',
                'padding:8px',
                'font:11px -apple-system,system-ui,sans-serif',
                'pointer-events:auto',
                'z-index:2147483647',
                'display:none',
                'box-sizing:border-box'
            ].join(';');

            popoverLabel = document.createElement('div');
            popoverLabel.style.cssText = [
                'color:#5AC8FA',
                'font:600 10px/14px ui-monospace,SFMono-Regular,Menlo,monospace',
                'margin-bottom:4px',
                'white-space:nowrap',
                'overflow:hidden',
                'text-overflow:ellipsis'
            ].join(';');

            popoverTextarea = document.createElement('textarea');
            popoverTextarea.setAttribute('rows', '3');
            popoverTextarea.setAttribute('placeholder', 'Add a comment…');
            popoverTextarea.style.cssText = [
                'width:100%', 'box-sizing:border-box',
                'background:rgba(255,255,255,0.06)',
                'color:#fff',
                'border:1px solid rgba(255,255,255,0.18)',
                'border-radius:4px',
                'padding:4px 6px',
                'font:12px -apple-system,system-ui,sans-serif',
                'resize:vertical',
                'min-height:48px',
                'outline:none'
            ].join(';');

            popoverTextarea.addEventListener('input', function() {
                if (!focusedID) return;
                var marker = markers[focusedID];
                if (marker) marker.comment = popoverTextarea.value;
                try {
                    bridge && bridge.postMessage({
                        commentChanged: { id: focusedID, comment: popoverTextarea.value }
                    });
                } catch (e) {}
            });
            // Esc inside the popover = Done. Don't let it bubble to
            // the inspector picker (which uses Esc to cancel arming
            // entirely).
            popoverTextarea.addEventListener('keydown', function(ev) {
                if (ev.key === 'Escape') {
                    ev.preventDefault();
                    ev.stopPropagation();
                    if (focusedID) sendDismiss(focusedID);
                }
            });
            // Stop clicks inside the popover from bubbling up to
            // page-level handlers (the editable textarea is its own
            // interactive surface).
            popoverTextarea.addEventListener('click', function(ev) {
                ev.stopPropagation();
            });
            popoverTextarea.addEventListener('mousedown', function(ev) {
                ev.stopPropagation();
            });

            // Footer row with Remove + Done buttons.
            var footer = document.createElement('div');
            footer.style.cssText = [
                'display:flex', 'align-items:center',
                'justify-content:space-between',
                'gap:6px',
                'margin-top:6px'
            ].join(';');

            var removeBtn = makePopoverButton('Remove', {
                background: 'transparent',
                color: '#FF6B6B',
                border: '1px solid rgba(255,107,107,0.4)'
            });
            removeBtn.addEventListener('click', function(ev) {
                ev.preventDefault();
                ev.stopPropagation();
                if (focusedID) sendRemove(focusedID);
            });

            var doneBtn = makePopoverButton('Done', {
                background: '#007AFF',
                color: '#fff',
                border: '1px solid #007AFF'
            });
            doneBtn.addEventListener('click', function(ev) {
                ev.preventDefault();
                ev.stopPropagation();
                if (focusedID) sendDismiss(focusedID);
            });

            footer.appendChild(removeBtn);
            footer.appendChild(doneBtn);

            popover.appendChild(popoverLabel);
            popover.appendChild(popoverTextarea);
            popover.appendChild(footer);
            ensureContainer().appendChild(popover);
            return popover;
        }

        function makePopoverButton(label, palette) {
            var btn = document.createElement('button');
            btn.type = 'button';
            btn.textContent = label;
            btn.style.cssText = [
                'background:' + palette.background,
                'color:' + palette.color,
                'border:' + palette.border,
                'border-radius:4px',
                'padding:3px 10px',
                'font:600 11px -apple-system,system-ui,sans-serif',
                'cursor:pointer',
                'min-width:60px'
            ].join(';');
            btn.addEventListener('mousedown', function(ev) {
                ev.stopPropagation();
            });
            return btn;
        }

        function sendDismiss(id) {
            try {
                bridge && bridge.postMessage({ dismiss: { id: String(id) } });
            } catch (e) {}
        }

        function sendRemove(id) {
            try {
                bridge && bridge.postMessage({ remove: { id: String(id) } });
            } catch (e) {}
        }

        function hidePopover() {
            if (popover) popover.style.display = 'none';
            window.__nexBatchHasOpenPopover = false;
        }

        function positionPopover() {
            if (!focusedID) { hidePopover(); return; }
            var m = markers[focusedID];
            if (!m) { hidePopover(); return; }
            var el = queryElement(m.selector);
            if (!el) { hidePopover(); return; }
            var rect = el.getBoundingClientRect();
            var vw = window.innerWidth;
            var vh = window.innerHeight;
            var collapsed = rect.width === 0 && rect.height === 0;
            var offscreen = rect.bottom <= 0 || rect.right <= 0 ||
                            rect.top >= vh || rect.left >= vw;
            if (collapsed || offscreen) { hidePopover(); return; }
            var pop = ensurePopover();
            pop.style.display = 'block';

            // Placement: below the element when there's room, else
            // above. Horizontally centered to the viewport (not the
            // element) so the popover always lands in a predictable
            // spot regardless of where on the page the picked
            // element sits. Clamped to the viewport with an 8px
            // margin.
            var popWidth = 260;
            var popHeight = pop.offsetHeight || 120;
            var roomBelow = vh - rect.bottom;
            var roomAbove = rect.top;
            var top;
            if (roomBelow >= popHeight + 16 || roomBelow >= roomAbove) {
                top = rect.bottom + 8;
            } else {
                top = rect.top - popHeight - 8;
            }
            if (top + popHeight > vh - 8) top = vh - popHeight - 8;
            if (top < 8) top = 8;

            var left = Math.round((vw - popWidth) / 2);
            if (left < 8) left = 8;
            if (left + popWidth > vw - 8) left = vw - popWidth - 8;

            pop.style.left = left + 'px';
            pop.style.top = top + 'px';
            // Set the picker-gating flag every time we (re)show
            // the popover. Cross-script signal — read in the
            // inspector picker's onClick / onMove.
            window.__nexBatchHasOpenPopover = true;
        }

        function syncPopoverContent() {
            if (!focusedID || !popover) return;
            var m = markers[focusedID];
            if (!m) return;
            if (popoverLabel) {
                popoverLabel.textContent = (m.label != null ? '#' + m.label + ' ' : '') + (m.selector || '');
            }
            // Only overwrite the textarea when the user isn't
            // actively typing (avoids clobbering their cursor).
            if (popoverTextarea && document.activeElement !== popoverTextarea) {
                popoverTextarea.value = m.comment || '';
            }
        }

        function updateExternalComment(id, comment) {
            var key = String(id);
            var m = markers[key];
            if (!m) return;
            m.comment = comment || '';
            if (focusedID === key &&
                popoverTextarea &&
                document.activeElement !== popoverTextarea) {
                popoverTextarea.value = m.comment;
            }
        }

        function positionBadge(marker) {
            if (!marker.badgeEl) return;
            var el = queryElement(marker.selector);
            if (!el) { marker.badgeEl.style.display = 'none'; return; }
            var rect = el.getBoundingClientRect();
            // Hide when the element is collapsed (display:none) or
            // fully outside the viewport — clamping the badge to the
            // viewport edge would otherwise leave dots floating with
            // no obvious owner once the user scrolls.
            var vw = window.innerWidth;
            var vh = window.innerHeight;
            var collapsed = rect.width === 0 && rect.height === 0;
            var offscreen = rect.bottom <= 0 || rect.right <= 0 ||
                            rect.top >= vh || rect.left >= vw;
            if (collapsed || offscreen) {
                marker.badgeEl.style.display = 'none';
                return;
            }
            marker.badgeEl.style.display = 'flex';
            // Place at top-left, slightly outside the element so it
            // doesn't cover the content. Follow the element off-screen
            // (no clamp) so partially-visible elements show the badge
            // beside them rather than pinned to the corner.
            marker.badgeEl.style.left = (rect.left - 6) + 'px';
            marker.badgeEl.style.top = (rect.top - 6) + 'px';
        }

        function refreshAll() {
            for (var id in markers) positionBadge(markers[id]);
            positionFocusRing();
            positionPopover();
        }

        function createBadge(marker) {
            var el = document.createElement('div');
            el.setAttribute('data-nex-batch-marker', '1');
            el.style.cssText = [
                'position:fixed',
                'min-width:18px', 'height:18px',
                'padding:0 5px',
                'border-radius:9px',
                'background:#007AFF', 'color:white',
                'font:600 11px/18px -apple-system,system-ui,sans-serif',
                'text-align:center',
                'box-sizing:content-box',
                'border:2px solid white',
                'box-shadow:0 1px 4px rgba(0,0,0,0.35)',
                'cursor:pointer',
                'pointer-events:auto',
                'z-index:2147483646',
                'user-select:none',
                'transition:transform 180ms ease',
                'display:flex', 'align-items:center', 'justify-content:center'
            ].join(';');
            el.textContent = String(marker.label);
            el.addEventListener('click', function(ev) {
                ev.preventDefault();
                ev.stopPropagation();
                try { bridge && bridge.postMessage({ id: marker.id }); } catch (e) {}
            });
            return el;
        }

        function setMarkers(items) {
            // Diff-rebuild without clearing focusedID — a full
            // clearAll() would drop the focus ring + popover state
            // on every state change (every new pick, every comment
            // edit on the panel side, …) and the user would see
            // the ring vanish for items 2+.
            for (var id in markers) {
                if (markers[id].badgeEl) markers[id].badgeEl.remove();
            }
            markers = {};
            if (!items || !items.length) {
                // Nothing to mark; tear down the focus surfaces too.
                clearFocusRing();
                hidePopover();
                if (container) { container.remove(); container = null; }
                return;
            }
            ensureContainer();
            items.forEach(function(item, i) {
                if (!item || !item.selector) return;
                if (!queryElement(item.selector)) return;
                var marker = {
                    id: String(item.id || ''),
                    selector: item.selector,
                    label: String(item.label != null ? item.label : (i + 1)),
                    comment: String(item.comment || ''),
                    badgeEl: null
                };
                var badge = createBadge(marker);
                container.appendChild(badge);
                marker.badgeEl = badge;
                markers[marker.id] = marker;
                positionBadge(marker);
            });
            // Apply any pending focus request that arrived before
            // this sync (highlight-before-setMarkers race).
            if (pendingFocusID && markers[pendingFocusID]) {
                focusedID = pendingFocusID;
                pendingFocusID = null;
            }
            // Restore (or clean up) the focus surfaces depending on
            // whether the focused item is still in the set.
            if (focusedID && !markers[focusedID]) {
                clearFocusRing();
                hidePopover();
            } else if (focusedID) {
                syncPopoverContent();
                positionFocusRing();
                positionPopover();
            }
        }

        function highlight(id, scrollIntoView) {
            var key = String(id);
            var m = markers[key];
            if (!m) {
                // Marker not yet synced (highlight arrived first in
                // the merge); remember and apply once setMarkers
                // catches up.
                pendingFocusID = key;
                return;
            }
            pendingFocusID = null;
            focusedID = key;
            var shouldScroll = scrollIntoView !== false;
            var el = queryElement(m.selector);
            if (el && shouldScroll) {
                try { el.scrollIntoView({ behavior: 'smooth', block: 'center' }); }
                catch (e) { el.scrollIntoView(); }
            }
            // Pulse the badge so a returning user sees which one is
            // currently selected.
            if (m.badgeEl) {
                m.badgeEl.style.transform = 'scale(1.6)';
                setTimeout(function() {
                    if (m.badgeEl) m.badgeEl.style.transform = 'scale(1)';
                }, 320);
            }
            // Draw the focus ring + popover immediately at the
            // current rect; reposition after the scroll animation
            // settles so they stay anchored.
            syncPopoverContent();
            positionFocusRing();
            positionPopover();
            if (shouldScroll) setTimeout(refreshAll, 400);
        }

        function unfocus() {
            clearFocusRing();
            hidePopover();
        }

        window.addEventListener('scroll', refreshAll, true);
        window.addEventListener('resize', refreshAll, true);

        window.__nexBatchSetMarkers = setMarkers;
        window.__nexBatchClearMarkers = clearAll;
        window.__nexBatchHighlight = highlight;
        window.__nexBatchUnfocus = unfocus;
        window.__nexBatchUpdateComment = updateExternalComment;
    })();
    """
}
