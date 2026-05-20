import Foundation
@testable import Nex
import Testing
import WebKit

/// Tests for `__nexAct.wait(opts)`. Drives the actuator inside a
/// hidden WKWebView; uses fixtures that mutate the DOM after a
/// `setTimeout` to verify the wait resolves on the transition, not
/// just on the initial state.
@MainActor
struct WebPaneActuatorWaitTests {
    // MARK: - immediate resolve

    @Test func waitExistsResolvesImmediatelyWhenAlreadyPresent() async throws {
        let host = try await ActuatorTestHost.make(html: "<p id=\"p\">hello</p>")
        let parsed = try await host.parse(
            host.evalAsyncString("return JSON.stringify(await __nexAct.wait({selector:'css:#p',for:'exists'}))")
        )
        #expect(parsed["ok"] as? Bool == true)
        #expect(parsed["condition"] as? String == "exists")
        // waited_ms is 0 on immediate hit — confirms we short-circuit
        // before the first setInterval tick.
        #expect(parsed["waited_ms"] as? Int == 0)
    }

    @Test func waitVisibleResolvesImmediatelyWhenAlreadyVisible() async throws {
        let host = try await ActuatorTestHost.make(html: "<p id=\"p\">hello</p>")
        let parsed = try await host.parse(
            host.evalAsyncString("return JSON.stringify(await __nexAct.wait({selector:'css:#p',for:'visible'}))")
        )
        #expect(parsed["ok"] as? Bool == true)
        #expect(parsed["condition"] as? String == "visible")
    }

    @Test func waitVisibleResolvesForFixedPositionElement() async throws {
        // Regression: offsetParent is null for position:fixed, so the
        // previous check classified visible overlays/toasts as hidden.
        // getClientRects()-based check resolves immediately.
        let host = try await ActuatorTestHost.make(html: """
        <div id="toast" style="position:fixed;top:0;left:0;width:100px;height:30px;background:red">hi</div>
        """)
        let parsed = try await host.parse(
            host.evalAsyncString("return JSON.stringify(await __nexAct.wait({selector:'css:#toast',for:'visible',timeout:300}))")
        )
        #expect(parsed["ok"] as? Bool == true)
        #expect(parsed["waited_ms"] as? Int == 0)
    }

    @Test func waitHiddenResolvesForVisibilityHidden() async throws {
        // visibility:hidden elements still have getClientRects, so we
        // must also consult computed style. Without that check, this
        // wait would time out.
        let host = try await ActuatorTestHost.make(html: """
        <p id="p" style="visibility:hidden">hi</p>
        """)
        let parsed = try await host.parse(
            host.evalAsyncString("return JSON.stringify(await __nexAct.wait({selector:'css:#p',for:'hidden',timeout:300}))")
        )
        #expect(parsed["ok"] as? Bool == true)
    }

    // MARK: - deferred transitions

    @Test func waitForExistsResolvesAfterDOMInsertion() async throws {
        // Element doesn't exist at load; a setTimeout adds it after
        // ~150ms. wait() must poll the page and resolve when the
        // element appears.
        let host = try await ActuatorTestHost.make(html: """
        <div id="root"></div>
        <script>
        setTimeout(function() {
            var p = document.createElement('p');
            p.id = 'late';
            p.textContent = 'Loaded';
            document.getElementById('root').appendChild(p);
        }, 150);
        </script>
        """)
        let parsed = try await host.parse(
            host.evalAsyncString("return JSON.stringify(await __nexAct.wait({selector:'css:#late',for:'exists',timeout:2000}))")
        )
        #expect(parsed["ok"] as? Bool == true)
        // Should fire on the first 100ms tick after the insert.
        let waited = parsed["waited_ms"] as? Int ?? 0
        #expect(waited >= 100)
        #expect(waited < 1000)
    }

    @Test func waitForHiddenResolvesAfterDisplayNone() async throws {
        let host = try await ActuatorTestHost.make(html: """
        <p id="p">hello</p>
        <script>
        setTimeout(function() {
            document.getElementById('p').style.display = 'none';
        }, 150);
        </script>
        """)
        let parsed = try await host.parse(
            host.evalAsyncString("return JSON.stringify(await __nexAct.wait({selector:'css:#p',for:'hidden',timeout:2000}))")
        )
        #expect(parsed["ok"] as? Bool == true)
        #expect(parsed["condition"] as? String == "hidden")
    }

    @Test func waitForCountResolvesAtTarget() async throws {
        let host = try await ActuatorTestHost.make(html: """
        <ul id="u"><li>a</li><li>b</li></ul>
        <script>
        setTimeout(function() {
            var u = document.getElementById('u');
            var li = document.createElement('li');
            li.textContent = 'c';
            u.appendChild(li);
        }, 150);
        </script>
        """)
        let parsed = try await host.parse(
            host.evalAsyncString("return JSON.stringify(await __nexAct.wait({selector:'css:li',for:'count=3',timeout:2000}))")
        )
        #expect(parsed["ok"] as? Bool == true)
        #expect(parsed["condition"] as? String == "count=3")
    }

    @Test func waitForTextMatchResolvesOnContentChange() async throws {
        let host = try await ActuatorTestHost.make(html: """
        <p id="p">loading</p>
        <script>
        setTimeout(function() {
            document.getElementById('p').textContent = 'Loaded';
        }, 150);
        </script>
        """)
        let parsed = try await host.parse(
            host.evalAsyncString("return JSON.stringify(await __nexAct.wait({selector:'css:#p',for:'text=Loaded',timeout:2000}))")
        )
        #expect(parsed["ok"] as? Bool == true)
    }

    @Test func waitForTextRegexResolves() async throws {
        let host = try await ActuatorTestHost.make(html: """
        <p id="p">loading</p>
        <script>
        setTimeout(function() {
            document.getElementById('p').textContent = 'Loaded successfully';
        }, 150);
        </script>
        """)
        let parsed = try await host.parse(
            host.evalAsyncString("return JSON.stringify(await __nexAct.wait({selector:'css:#p',for:'text=/^Loaded/',timeout:2000}))")
        )
        #expect(parsed["ok"] as? Bool == true)
    }

    // MARK: - timeout

    @Test func waitTimesOutOnMissingSelector() async throws {
        let host = try await ActuatorTestHost.make(html: "<div></div>")
        let parsed = try await host.parse(
            host.evalAsyncString("return JSON.stringify(await __nexAct.wait({selector:'css:#never',for:'exists',timeout:300}))")
        )
        #expect(parsed["ok"] as? Bool == false)
        #expect(parsed["error"] as? String == "timeout")
        let waited = parsed["waited_ms"] as? Int ?? 0
        // Allow some slack — the interval fires every 100ms so the
        // first post-timeout check lands in the 300-400ms band.
        #expect(waited >= 300)
        #expect(waited < 700)
    }

    @Test func waitDefaultsToExistsWhenForOmitted() async throws {
        let host = try await ActuatorTestHost.make(html: "<p id=\"p\">x</p>")
        let parsed = try await host.parse(
            host.evalAsyncString("return JSON.stringify(await __nexAct.wait({selector:'css:#p'}))")
        )
        #expect(parsed["ok"] as? Bool == true)
        #expect(parsed["condition"] as? String == "exists")
    }

    // MARK: - validation

    @Test func waitRejectsCountWithoutSelector() async throws {
        let host = try await ActuatorTestHost.make(html: "<div></div>")
        let parsed = try await host.parse(
            host.evalAsyncString("return JSON.stringify(await __nexAct.wait({for:'count=3'}))")
        )
        #expect(parsed["ok"] as? Bool == false)
        #expect((parsed["error"] as? String)?.contains("requires selector") == true)
    }

    @Test func waitRejectsBadTextRegex() async throws {
        let host = try await ActuatorTestHost.make(html: "<p id=\"p\">x</p>")
        let parsed = try await host.parse(
            host.evalAsyncString("return JSON.stringify(await __nexAct.wait({selector:'css:#p',for:'text=/(/'}))")
        )
        #expect(parsed["ok"] as? Bool == false)
        #expect((parsed["error"] as? String)?.contains("bad regex") == true)
    }

    @Test func waitRejectsUnknownCondition() async throws {
        let host = try await ActuatorTestHost.make(html: "<div></div>")
        let parsed = try await host.parse(
            host.evalAsyncString("return JSON.stringify(await __nexAct.wait({selector:'css:div',for:'shimmery'}))")
        )
        #expect(parsed["ok"] as? Bool == false)
        #expect((parsed["error"] as? String)?.contains("unknown condition") == true)
    }
}
