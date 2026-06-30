import Foundation

/// The bundled mermaid library and the small init script that turns the
/// renderer's `[data-nex-mermaid]` placeholders into inline SVG diagrams.
///
/// Both are injected on demand (only when the current document actually
/// contains a mermaid block) via `evaluateJavaScript`, rather than as an
/// always-on `WKUserScript`, so non-mermaid previews never pay the ~2.5MB
/// library cost. The trade-off is that each reload of a mermaid document
/// (file save, appearance toggle, font-size change) re-evaluates the
/// library in the fresh JS context — acceptable because it runs in the web
/// content process (off the app's main thread) and only for documents that
/// actually contain a diagram.
///
/// Provenance: `Nex/Resources/mermaid.min.js` is vendored verbatim from
/// https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.min.js
/// (mermaid v11.4.1, MIT). To update, re-download that URL — it must be the
/// UMD build whose tail is `globalThis.mermaid = …`.
enum MarkdownMermaidScript {
    /// The vendored mermaid UMD bundle (`Nex/Resources/mermaid.min.js`),
    /// read once and cached. The bundle ends with
    /// `globalThis.mermaid = …`, so evaluating this string defines
    /// `window.mermaid`. The trailing `;void 0;` stops WebKit trying to
    /// serialize the multi-megabyte last-expression value back across the
    /// process boundary into the `evaluateJavaScript` completion handler.
    /// Empty string if the resource is missing — `runSource` then takes
    /// the `typeof mermaid === 'undefined'` path and reveals the source
    /// as a plain code block.
    static let librarySource: String = {
        guard let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return js + "\n;void 0;"
    }()

    /// Init/render script. Reads light/dark from the live `<html>` class
    /// (baked in by `MarkdownRenderer`), renders every `[data-nex-mermaid]`
    /// block, and posts `{ token }` to the `mermaidRendered` message
    /// handler once all blocks have settled so the coordinator can restore
    /// scroll *after* the layout-changing SVGs are in place. `token` is the
    /// coordinator's render token so stale reloads can be dropped.
    static func runSource(token: UInt64) -> String {
        """
        (function() {
          var TOKEN = \(token);
          function done() {
            try {
              window.webkit.messageHandlers.mermaidRendered.postMessage({ token: TOKEN });
            } catch (e) {}
          }
          function fallback(block, src, message) {
            block.classList.remove('mermaid-rendered');
            block.classList.add('mermaid-error');
            block.innerHTML = '';
            if (message) {
              var note = document.createElement('div');
              note.className = 'mermaid-error-note';
              note.textContent = message;
              block.appendChild(note);
            }
            // Mirror the standard fenced-code-block markup so the always-on
            // copy script (delegated `.code-copy-btn` click → `:scope > pre >
            // code`) makes the diagram source copyable, just like any other
            // code block.
            var wrap = document.createElement('div');
            wrap.className = 'code-block';
            var pre = document.createElement('pre');
            var code = document.createElement('code');
            code.className = 'language-mermaid';
            code.textContent = src;
            pre.appendChild(code);
            wrap.appendChild(pre);
            var btn = document.createElement('button');
            btn.className = 'code-copy-btn';
            btn.type = 'button';
            btn.setAttribute('aria-label', 'Copy code');
            wrap.appendChild(btn);
            block.appendChild(wrap);
          }
          function sourceOf(block) {
            var el = block.querySelector('.mermaid-source');
            return el ? el.textContent : block.textContent;
          }
          var blocks = Array.prototype.slice.call(
            document.querySelectorAll('[data-nex-mermaid]')
          );
          if (!blocks.length) { done(); return; }
          if (typeof mermaid === 'undefined') {
            blocks.forEach(function(b) { fallback(b, sourceOf(b), null); });
            done();
            return;
          }
          try {
            var isDark = document.documentElement.classList.contains('dark');
            mermaid.initialize({
              startOnLoad: false,
              securityLevel: 'strict',
              theme: isDark ? 'dark' : 'default',
              fontFamily: "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif"
            });
          } catch (e) {}
          // Render sequentially. mermaid keeps global parser/config state, so
          // firing render() for every block concurrently can cross-wire or
          // intermittently fail on multi-diagram documents — await each
          // before starting the next, then post `done()` once.
          (async function() {
            for (var i = 0; i < blocks.length; i++) {
              var block = blocks[i];
              var src = sourceOf(block);
              if (!src || !src.trim()) {
                // Empty fence: render nothing rather than an error note.
                block.classList.add('mermaid-rendered');
                block.innerHTML = '';
                continue;
              }
              // Letter-prefixed so the id is a valid selector even when i
              // would otherwise start it with a digit; unique per block so
              // mermaid's temporary measurement node never collides.
              var id = 'nex-mermaid-' + i;
              try {
                var res = await mermaid.render(id, src);
                block.innerHTML = res.svg;
                block.classList.add('mermaid-rendered');
                if (res.bindFunctions) {
                  try { res.bindFunctions(block); } catch (e) {}
                }
              } catch (err) {
                fallback(block, src, 'Diagram failed to render: ' +
                  (err && err.message ? err.message : err));
              }
            }
            done();
          })();
        })();
        """
    }
}
