import Foundation

/// JavaScript injected into every markdown preview WKWebView. Defines
/// `window.__nexFind` with `search(needle)`, `next()`, `prev()`, and
/// `clear()`. Each call posts a result back via the `nexFind` script
/// message: `{ total: Int, current: Int }` (current is `-1` when there
/// is no active match).
enum MarkdownFindScript {
    static let source: String = """
    (function() {
      if (window.__nexFind) { return; }
      var ns = {};
      window.__nexFind = ns;
      ns.matches = [];
      ns.currentIndex = -1;

      var styleEl = document.createElement('style');
      // Colors mirror ghostty's `search-background` /
      // `search-selected-background` (set by NexGhosttyDefaults) so
      // terminal find and markdown find share a palette.
      styleEl.textContent = (
        "mark.nex-find-match { background: #F2D027; color: #000; border-radius: 2px; padding: 0; }" +
        "mark.nex-find-match.nex-find-current { background: #FF7A00; color: #000; }"
      );
      // Defer until <head> exists. Inject CSS via JS so that the
      // markdown HTML renderer doesn't need to know about find styling.
      function injectStyle() {
        if (document.head) {
          document.head.appendChild(styleEl);
        } else {
          requestAnimationFrame(injectStyle);
        }
      }
      injectStyle();

      function postResult() {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nexFind) {
          window.webkit.messageHandlers.nexFind.postMessage({
            total: ns.matches.length,
            current: ns.matches.length === 0 ? -1 : ns.currentIndex
          });
        }
      }

      function clearMarks() {
        var marks = document.querySelectorAll('mark.nex-find-match');
        for (var i = 0; i < marks.length; i++) {
          var m = marks[i];
          var parent = m.parentNode;
          if (!parent) continue;
          while (m.firstChild) parent.insertBefore(m.firstChild, m);
          parent.removeChild(m);
          parent.normalize();
        }
        ns.matches = [];
        ns.currentIndex = -1;
      }

      function setCurrent(scroll) {
        var prev = document.querySelectorAll('mark.nex-find-match.nex-find-current');
        for (var i = 0; i < prev.length; i++) prev[i].classList.remove('nex-find-current');
        if (ns.currentIndex >= 0 && ns.currentIndex < ns.matches.length) {
          var m = ns.matches[ns.currentIndex];
          m.classList.add('nex-find-current');
          if (scroll) m.scrollIntoView({ block: 'center', inline: 'nearest' });
        }
      }

      function shouldSkipNode(node) {
        var p = node.parentNode;
        while (p) {
          if (p.nodeType !== 1) { p = p.parentNode; continue; }
          var tag = p.tagName;
          if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT') return true;
          if (p.classList && p.classList.contains('nex-find-match')) return true;
          p = p.parentNode;
        }
        return false;
      }

      function escapeRegex(s) {
        return s.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
      }

      function search(needle) {
        clearMarks();
        if (!needle) { postResult(); return; }
        // Use a regex with the `i` flag so case folding is done by the
        // engine itself. This avoids the offset drift that bites
        // `text.toLowerCase().indexOf(needle.toLowerCase())` when
        // `toLowerCase()` changes string length (e.g. Turkish dotted I,
        // German eszett) — the regex always returns offsets that line
        // up with the original text.
        var rx;
        try {
          rx = new RegExp(escapeRegex(needle), 'gi');
        } catch (e) {
          postResult();
          return;
        }

        var walker = document.createTreeWalker(
          document.body,
          NodeFilter.SHOW_TEXT,
          {
            acceptNode: function(node) {
              if (!node.nodeValue) return NodeFilter.FILTER_REJECT;
              if (shouldSkipNode(node)) return NodeFilter.FILTER_REJECT;
              return NodeFilter.FILTER_ACCEPT;
            }
          }
        );
        var textNodes = [];
        var n;
        while ((n = walker.nextNode())) textNodes.push(n);

        var matches = [];
        for (var t = 0; t < textNodes.length; t++) {
          var node = textNodes[t];
          var text = node.nodeValue;
          rx.lastIndex = 0;
          var first = rx.exec(text);
          if (!first) continue;
          var parent = node.parentNode;
          if (!parent) continue;
          var cursor = 0;
          var fragments = [];
          var m = first;
          while (m) {
            var idx = m.index;
            var len = m[0].length;
            if (len === 0) { rx.lastIndex = idx + 1; m = rx.exec(text); continue; }
            if (idx > cursor) {
              fragments.push(document.createTextNode(text.slice(cursor, idx)));
            }
            var mark = document.createElement('mark');
            mark.className = 'nex-find-match';
            mark.appendChild(document.createTextNode(text.slice(idx, idx + len)));
            fragments.push(mark);
            matches.push(mark);
            cursor = idx + len;
            m = rx.exec(text);
          }
          if (cursor < text.length) {
            fragments.push(document.createTextNode(text.slice(cursor)));
          }
          for (var f = 0; f < fragments.length; f++) {
            parent.insertBefore(fragments[f], node);
          }
          parent.removeChild(node);
        }

        ns.matches = matches;
        ns.currentIndex = matches.length > 0 ? 0 : -1;
        setCurrent(true);
        postResult();
      }

      function navigate(delta) {
        if (ns.matches.length === 0) { postResult(); return; }
        ns.currentIndex = (ns.currentIndex + delta + ns.matches.length) % ns.matches.length;
        setCurrent(true);
        postResult();
      }

      ns.search = search;
      ns.next = function() { navigate(1); };
      ns.prev = function() { navigate(-1); };
      ns.clear = function() { clearMarks(); postResult(); };
    })();
    """

    /// JSON-encode the needle so it can be inlined inside `JS.search(...)`.
    /// Falls back to `""` on encoding failure.
    static func encodeNeedle(_ needle: String) -> String {
        guard let data = try? JSONEncoder().encode(needle),
              let s = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return s
    }
}
