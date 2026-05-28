import Foundation

/// JavaScript injected into every markdown preview WKWebView. Wires the
/// per-code-block copy button: posts the raw code text through the
/// `copyCodeBlock` script message handler and shows a transient
/// checkmark on the button via the `.copied` class.
enum MarkdownCodeCopyScript {
    static let source: String = """
    (function() {
        if (window.__nexCopyCodeBound) { return; }
        window.__nexCopyCodeBound = true;

        var COPIED_MS = 1500;

        document.addEventListener('click', function(e) {
            var btn = e.target.closest && e.target.closest('.code-copy-btn');
            if (!btn) { return; }
            // Re-entry guard so a second click during the "copied" window
            // doesn't reset the visual state mid-animation.
            if (btn.classList.contains('copied')) { return; }
            var wrap = btn.parentNode;
            if (!wrap) { return; }
            // `:scope >` requires a direct <pre> child so we don't pick up
            // a nested code block if the structure ever changes.
            var code = wrap.querySelector(':scope > pre > code');
            if (!code) { return; }
            var text = code.textContent;
            if (!text) { return; }
            try {
                window.webkit.messageHandlers.copyCodeBlock.postMessage(text);
            } catch (err) {
                return;
            }
            btn.classList.add('copied');
            // Announce the success state to assistive tech by swapping the
            // aria-label; the .copied class only changes a CSS icon.
            var origLabel = btn.getAttribute('aria-label') || 'Copy code';
            btn.setAttribute('aria-label', 'Copied');
            setTimeout(function() {
                btn.classList.remove('copied');
                btn.setAttribute('aria-label', origLabel);
            }, COPIED_MS);
        });
    })();
    """
}
