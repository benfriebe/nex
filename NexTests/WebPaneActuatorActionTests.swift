import Foundation
@testable import Nex
import Testing
import WebKit

/// Action verb tests for `__nexAct.click` / `__nexAct.type`. Drives
/// the actuator inside a hidden WKWebView and asserts the resulting
/// DOM state. Covers the regression we burned a chunk of restaurant-
/// ordering session debugging on: React-style controlled inputs that
/// ignore `.value = ...` because the synthetic React setter is on
/// the instance and the prototype setter has to be invoked instead.
@MainActor
struct WebPaneActuatorActionTests {
    // MARK: - click

    @Test func clickFiresFullPointerSequence() async throws {
        let host = try await ActuatorActionTestHost.make(html: """
        <button id="b">go</button>
        <script>
        window.__events = [];
        var b = document.getElementById('b');
        ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(name) {
            b.addEventListener(name, function() { window.__events.push(name); });
        });
        </script>
        """)
        let reply = try await host.eval("JSON.stringify(__nexAct.click('css:#b'))")
        let events = try await host.eval("JSON.stringify(window.__events)")
        let parsed = try host.parse(reply as? String ?? "")
        #expect(parsed["ok"] as? Bool == true)
        #expect(parsed["text"] as? String == "go")
        #expect((events as? String) == "[\"pointerdown\",\"mousedown\",\"pointerup\",\"mouseup\",\"click\"]")
    }

    @Test func clickReturnsNotFoundForUnknownSelector() async throws {
        let host = try await ActuatorActionTestHost.make(html: "<div></div>")
        let reply = try await host.eval("JSON.stringify(__nexAct.click('text:Not there'))")
        let parsed = try host.parse(reply as? String ?? "")
        #expect(parsed["ok"] as? Bool == false)
        #expect((parsed["error"] as? String)?.contains("no match") == true)
    }

    @Test func clickDoubleFiresDblclick() async throws {
        let host = try await ActuatorActionTestHost.make(html: """
        <button id="b">go</button>
        <script>
        window.__count = 0;
        document.getElementById('b').addEventListener('dblclick', function() {
            window.__count++;
        });
        </script>
        """)
        _ = try await host.eval("__nexAct.click('css:#b', {double: true})")
        let count = try await host.eval("window.__count")
        #expect(count as? Int == 1)
    }

    @Test func clickRightFiresContextMenuNotClick() async throws {
        let host = try await ActuatorActionTestHost.make(html: """
        <button id="b">go</button>
        <script>
        window.__cm = 0; window.__clicks = 0;
        var b = document.getElementById('b');
        b.addEventListener('contextmenu', function(e) { window.__cm++; e.preventDefault(); });
        b.addEventListener('click', function() { window.__clicks++; });
        </script>
        """)
        _ = try await host.eval("__nexAct.click('css:#b', {right: true})")
        let cm = try await host.eval("window.__cm")
        let clicks = try await host.eval("window.__clicks")
        #expect(cm as? Int == 1)
        // .click() must not fire on right-click. mousedown still does
        // — that's a single-event difference from a real OS right-click
        // but matches Playwright behaviour.
        #expect(clicks as? Int == 0)
    }

    // MARK: - type

    @Test func typeSetsInputValueAndDispatchesEvents() async throws {
        let host = try await ActuatorActionTestHost.make(html: """
        <input id="i" type="text">
        <script>
        window.__inputEvents = 0; window.__changeEvents = 0;
        var i = document.getElementById('i');
        i.addEventListener('input', function() { window.__inputEvents++; });
        i.addEventListener('change', function() { window.__changeEvents++; });
        </script>
        """)
        let reply = try await host.eval("JSON.stringify(__nexAct.type('css:#i', 'hello'))")
        let parsed = try host.parse(reply as? String ?? "")
        #expect(parsed["ok"] as? Bool == true)
        #expect(parsed["value"] as? String == "hello")

        let value = try await host.eval("document.getElementById('i').value")
        #expect(value as? String == "hello")
        let inputs = try await host.eval("window.__inputEvents")
        let changes = try await host.eval("window.__changeEvents")
        #expect(inputs as? Int == 1)
        #expect(changes as? Int == 1)
    }

    @Test func typeReplacesByDefault() async throws {
        let host = try await ActuatorActionTestHost.make(html: """
        <input id="i" type="text" value="old">
        """)
        _ = try await host.eval("__nexAct.type('css:#i', 'new')")
        let value = try await host.eval("document.getElementById('i').value")
        #expect(value as? String == "new")
    }

    @Test func typeAppendsWhenReplaceFalse() async throws {
        let host = try await ActuatorActionTestHost.make(html: """
        <input id="i" type="text" value="abc">
        """)
        _ = try await host.eval("__nexAct.type('css:#i', 'def', {replace: false})")
        let value = try await host.eval("document.getElementById('i').value")
        #expect(value as? String == "abcdef")
    }

    @Test func typeUsesPrototypeSetterForReactControlledInputs() async throws {
        // React's controlled-input pattern: the page library monkey-
        // patches the `value` setter on each <input> instance to read
        // through to `state`. The instance-level setter has to be
        // bypassed via the prototype getOwnPropertyDescriptor or
        // controlled inputs revert to their state value on the next
        // render. The actuator must thread that needle.
        let host = try await ActuatorActionTestHost.make(html: """
        <input id="i" type="text">
        <script>
        window.__instanceSetterCalls = 0;
        var i = document.getElementById('i');
        // Pretend to be React: shadow the instance value setter with
        // one that counts but is otherwise inert. The actuator's
        // prototype-setter trick must bypass this and still write.
        Object.defineProperty(i, 'value', {
            get() { return this._real || ''; },
            set(v) { window.__instanceSetterCalls++; /* swallow */ }
        });
        // Use the prototype native setter directly to seed _real so
        // we can prove the actuator wrote through it.
        var protoSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        i._real = '';
        // Mirror the prototype setter into our backing field so an
        // actuator-driven write actually mutates state we can check.
        Object.defineProperty(HTMLInputElement.prototype, 'value', {
            configurable: true,
            get() { return this._real || ''; },
            set(v) { this._real = String(v); }
        });
        </script>
        """)
        _ = try await host.eval("__nexAct.type('css:#i', 'react-ok')")
        let backed = try await host.eval("document.getElementById('i')._real")
        #expect(backed as? String == "react-ok")
        // Instance setter should never have been called — we bypassed
        // it via Object.getOwnPropertyDescriptor on the prototype.
        let instanceCalls = try await host.eval("window.__instanceSetterCalls")
        #expect(instanceCalls as? Int == 0)
    }

    @Test func typeRejectsNonTypableElement() async throws {
        let host = try await ActuatorActionTestHost.make(html: """
        <button id="b">go</button>
        """)
        let reply = try await host.eval("JSON.stringify(__nexAct.type('css:#b', 'x'))")
        let parsed = try host.parse(reply as? String ?? "")
        #expect(parsed["ok"] as? Bool == false)
        #expect((parsed["error"] as? String)?.contains("not typable") == true)
    }

    @Test func typeSubmitFiresEnterKeydown() async throws {
        let host = try await ActuatorActionTestHost.make(html: """
        <input id="i" type="search">
        <script>
        window.__enter = 0;
        document.getElementById('i').addEventListener('keydown', function(e) {
            if (e.key === 'Enter') window.__enter++;
        });
        </script>
        """)
        _ = try await host.eval("__nexAct.type('css:#i', 'q', {submit: true})")
        let enter = try await host.eval("window.__enter")
        #expect(enter as? Int == 1)
    }

    @Test func typeIntoContentEditableElement() async throws {
        let host = try await ActuatorActionTestHost.make(html: """
        <div id="ce" contenteditable="true">old</div>
        """)
        _ = try await host.eval("__nexAct.type('css:#ce', 'new')")
        let text = try await host.eval("document.getElementById('ce').textContent")
        #expect(text as? String == "new")
    }
}

// MARK: - test host (shares the same WKWebView pattern as the

// selector tests but exposes a JSON-parser helper for action replies).

@MainActor
private final class ActuatorActionTestHost: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var didFinish: CheckedContinuation<Void, Error>?

    static func make(html: String) async throws -> ActuatorActionTestHost {
        let host = ActuatorActionTestHost()
        try await host.load(html: html)
        return host
    }

    override init() {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(
            source: WebPaneActuatorScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    func load(html: String) async throws {
        try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, Error>) in
            didFinish = cc
            webView.loadHTMLString(
                "<!doctype html><html><body>\(html)</body></html>",
                baseURL: nil
            )
        }
    }

    func eval(_ js: String) async throws -> Any? {
        try await webView.evaluateJavaScript(js)
    }

    /// Parse a JSON string produced by `JSON.stringify(...)` on the
    /// JS side. Throws if the input isn't a valid JSON object —
    /// surfaces as a test failure with the raw string in scope.
    func parse(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw NSError(domain: "ActuatorActionTestHost", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "not a JSON object: \(json)"
            ])
        }
        return parsed
    }

    nonisolated func webView(_: WKWebView, didFinish _: WKNavigation!) {
        Task { @MainActor in
            self.didFinish?.resume()
            self.didFinish = nil
        }
    }

    nonisolated func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.didFinish?.resume(throwing: error)
            self.didFinish = nil
        }
    }

    nonisolated func webView(
        _: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error
    ) {
        Task { @MainActor in
            self.didFinish?.resume(throwing: error)
            self.didFinish = nil
        }
    }
}
