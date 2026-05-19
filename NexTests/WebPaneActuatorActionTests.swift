import Foundation
@testable import Nex
import Testing
import WebKit

/// Action verb tests for `__nexAct.click` / `__nexAct.type`. Drives
/// the actuator inside a hidden WKWebView and asserts the resulting
/// DOM state. The React-controlled-input case is exercised because a
/// straight `el.value = x` is intercepted by the framework's instance
/// setter; the actuator must invoke the prototype setter to write.
@MainActor
struct WebPaneActuatorActionTests {
    // MARK: - click

    @Test func clickFiresFullPointerSequence() async throws {
        let host = try await ActuatorTestHost.make(html: """
        <button id="b">go</button>
        <script>
        window.__events = [];
        var b = document.getElementById('b');
        ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(name) {
            b.addEventListener(name, function() { window.__events.push(name); });
        });
        </script>
        """)
        let parsed = try await host.parse(
            host.evalString("JSON.stringify(__nexAct.click('css:#b'))")
        )
        let events = try await host.evalString("JSON.stringify(window.__events)")
        #expect(parsed["ok"] as? Bool == true)
        #expect(parsed["text"] as? String == "go")
        #expect(events == "[\"pointerdown\",\"mousedown\",\"pointerup\",\"mouseup\",\"click\"]")
    }

    @Test func clickReturnsNotFoundForUnknownSelector() async throws {
        let host = try await ActuatorTestHost.make(html: "<div></div>")
        let parsed = try await host.parse(
            host.evalString("JSON.stringify(__nexAct.click('text:Not there'))")
        )
        #expect(parsed["ok"] as? Bool == false)
        #expect((parsed["error"] as? String)?.contains("no match") == true)
    }

    @Test func clickDoubleFiresDblclick() async throws {
        let host = try await ActuatorTestHost.make(html: """
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
        let host = try await ActuatorTestHost.make(html: """
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

    @Test func clickAtDeliversCoordinatesToListener() async throws {
        // The default code path calls native target.click(), which
        // strips the synthesised clientX/Y. When `at` is supplied the
        // caller wants those coords on the listener, so the actuator
        // must dispatch a synthesised click instead. Canvas / custom-
        // control widgets are the motivating case.
        let host = try await ActuatorTestHost.make(html: """
        <div id="b" style="position:absolute;left:50px;top:80px;width:200px;height:100px"></div>
        <script>
        window.__cx = -1; window.__cy = -1;
        document.getElementById('b').addEventListener('click', function(e) {
            window.__cx = e.clientX; window.__cy = e.clientY;
        });
        </script>
        """)
        _ = try await host.eval("__nexAct.click('css:#b', {at: {x: 10, y: 20}})")
        let cx = try await host.eval("window.__cx")
        let cy = try await host.eval("window.__cy")
        // The element is offset (left=50, top=80) and the local point
        // is (10, 20), so the absolute clientX/Y must be 60 / 100.
        #expect(cx as? Int == 60)
        #expect(cy as? Int == 100)
    }

    // MARK: - type

    @Test func typeSetsInputValueAndDispatchesEvents() async throws {
        let host = try await ActuatorTestHost.make(html: """
        <input id="i" type="text">
        <script>
        window.__inputEvents = 0; window.__changeEvents = 0;
        var i = document.getElementById('i');
        i.addEventListener('input', function() { window.__inputEvents++; });
        i.addEventListener('change', function() { window.__changeEvents++; });
        </script>
        """)
        let parsed = try await host.parse(
            host.evalString("JSON.stringify(__nexAct.type('css:#i', 'hello'))")
        )
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
        let host = try await ActuatorTestHost.make(html: """
        <input id="i" type="text" value="old">
        """)
        _ = try await host.eval("__nexAct.type('css:#i', 'new')")
        let value = try await host.eval("document.getElementById('i').value")
        #expect(value as? String == "new")
    }

    @Test func typeAppendsWhenReplaceFalse() async throws {
        let host = try await ActuatorTestHost.make(html: """
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
        let host = try await ActuatorTestHost.make(html: """
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
        let host = try await ActuatorTestHost.make(html: """
        <button id="b">go</button>
        """)
        let parsed = try await host.parse(
            host.evalString("JSON.stringify(__nexAct.type('css:#b', 'x'))")
        )
        #expect(parsed["ok"] as? Bool == false)
        #expect((parsed["error"] as? String)?.contains("not typable") == true)
    }

    @Test func typeSubmitFiresEnterKeydown() async throws {
        let host = try await ActuatorTestHost.make(html: """
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
        let host = try await ActuatorTestHost.make(html: """
        <div id="ce" contenteditable="true">old</div>
        """)
        _ = try await host.eval("__nexAct.type('css:#ce', 'new')")
        let text = try await host.eval("document.getElementById('ce').textContent")
        #expect(text as? String == "new")
    }
}
