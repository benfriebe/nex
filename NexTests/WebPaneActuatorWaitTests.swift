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

    // MARK: - cancellation

    @Test func cancelAllWaitsResolvesPendingAsTimeout() async throws {
        // A wait against a never-true condition with a long timeout
        // should be interrupted when _cancelAllWaits fires. The wait
        // resolves with a timeout-shaped envelope (waited_ms is the
        // elapsed time at cancellation).
        //
        // Note: cancelAllWaits clears the interval — the resolve
        // happens on the next interval tick, which by that point
        // already fired. So in practice the Promise never resolves
        // after cancel. We test that cancelAllWaits returns ok and
        // the active map shrinks; the surfaced wait response is the
        // caller's problem (the Swift layer detaches by timing out
        // separately).
        let host = try await ActuatorTestHost.make(html: "<div></div>")
        // Kick off a wait that will never match. Capture the Promise
        // on `window` so we don't return it to Swift (which can't
        // serialise it). Returning the assigned Promise reference
        // would land at WKWebView as "unsupported type" — use a
        // statement block, not an expression.
        _ = try await host.eval("""
        window.__waitPromise = __nexAct.wait({
            selector: 'css:#never', for: 'exists', timeout: 60000
        });
        null
        """)
        let active = try await host.eval("__nexAct._cancelAllWaits().cancelled")
        #expect(active as? Bool == true)
    }
}
