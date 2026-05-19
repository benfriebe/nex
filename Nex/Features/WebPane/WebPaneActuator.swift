import Foundation

/// Swift-side façade in front of `window.__nexAct` (see
/// `WebPaneActuatorScript`). Each `nex web <verb>` handler in
/// `AppReducer` builds an `ActuatorCall` describing the JS method to
/// invoke + its arguments, hands it to `WebPaneActuator.invoke(...)`,
/// and forwards the resulting JSON envelope back to the CLI.
///
/// The Swift code never parses selectors or walks the DOM — every
/// observable behaviour of an actuator verb is defined by the JS
/// source. That single-source-of-truth rule is what lets a future
/// `web exec` call the same methods from inside user-authored scripts
/// and stay consistent with the verbs.
enum WebPaneActuator {
    /// Outcome of a single `__nexAct.*` invocation.
    ///
    /// - `success(payload)` — JS returned a structured reply. `payload`
    ///   is the JSON-encoded reply body (typically an `{ok, ...}`
    ///   object).
    /// - `unknownTab` — the coordinator has no WebView for that tab id
    ///   (pane was torn down between CLI dispatch and JS evaluation).
    /// - `evaluationFailed(message)` — JS threw, parsing the reply
    ///   failed, or the actuator was not present in the page.
    enum Result {
        case success(Data)
        case unknownTab
        case evaluationFailed(String)
    }

    /// Build the JS expression that calls `__nexAct.<method>(<args>)`,
    /// wrap it in a try/catch that JSON-stringifies the reply, then
    /// evaluate it via the coordinator. Returns the stringified JSON
    /// payload as a `Data` blob (`Sendable`-friendly so it can be
    /// handed to the socket reply path without crossing actor
    /// boundaries with a non-Sendable `[String: Any]`).
    @MainActor
    static func invoke(
        coordinator: WebPaneCoordinator,
        tabID: UUID,
        method: String,
        args: [JSValue]
    ) async -> Result {
        let argsJS = args.map(\.jsLiteral).joined(separator: ", ")
        // Wrap the call so that:
        //   * a missing __nexAct throws a recognisable string,
        //   * a thrown JS exception flattens into the reply envelope
        //     instead of bubbling up to `evaluateJavaScript` (which on
        //     some WebKit builds returns nil with no diagnostic),
        //   * the reply round-trips through JSON.stringify so the
        //     Swift side gets a single, easy-to-parse string.
        let source = """
        (function() {
            try {
                if (!window.__nexAct) {
                    return JSON.stringify({ok: false, error: 'actuator not installed'});
                }
                var r = window.__nexAct.\(method)(\(argsJS));
                return JSON.stringify(r === undefined ? null : r);
            } catch (e) {
                return JSON.stringify({
                    ok: false,
                    error: (e && e.message) ? e.message : String(e)
                });
            }
        })();
        """
        let raw = await coordinator.evaluateJavaScript(tabID: tabID, source: source)
        guard let string = raw as? String else {
            if coordinator.knowsTab(tabID: tabID) {
                return .evaluationFailed("actuator returned non-string reply")
            }
            return .unknownTab
        }
        guard let data = string.data(using: .utf8) else {
            return .evaluationFailed("reply not valid utf8")
        }
        return .success(data)
    }
}

// MARK: - JSValue: typed JS-literal builder

/// A small typed wrapper for the values we splice into a generated JS
/// expression. Kept tight — only the shapes `__nexAct.*` calls
/// currently need.
///
/// Object pairs use the named `JSPair` struct rather than a
/// `[(String, JSValue)]` tuple list because tuples don't auto-synthesise
/// `Sendable`. Explicit `Sendable` is required on both: the AppReducer
/// builds `[JSValue]` args inside `.run { _ in ... }` (a `@Sendable`
/// closure) and the conformance does not flow through `[T]` without it.
// swiftformat:disable redundantSendable
struct JSPair: Sendable {
    let key: String
    let value: JSValue
}

enum JSValue: Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSValue])
    case object([JSPair])

    var jsLiteral: String {
        switch self {
        case .null:
            return "null"
        case let .bool(b):
            return b ? "true" : "false"
        case let .int(i):
            return String(i)
        case let .double(d):
            // Use Swift's default formatting; JS parses both
            // 1 and 1.0 the same. Avoids locale issues by going
            // through `String(describing:)`.
            return String(describing: d)
        case let .string(s):
            return Self.encodeString(s)
        case let .array(items):
            return "[" + items.map(\.jsLiteral).joined(separator: ", ") + "]"
        case let .object(pairs):
            let body = pairs
                .map { Self.encodeString($0.key) + ": " + $0.value.jsLiteral }
                .joined(separator: ", ")
            return "{" + body + "}"
        }
    }

    /// JSON-encode a string into a JS string literal. JSONSerialization
    /// emits ASCII-safe JSON by default which is also valid JS, so we
    /// reuse it instead of hand-rolling the escape table.
    private static func encodeString(_ s: String) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: [s],
                options: [.fragmentsAllowed]
            ),
            let array = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        // `[s]` -> `["..."]`; strip the surrounding [ ].
        let trimmed = array.dropFirst().dropLast()
        return String(trimmed)
    }
}

// swiftformat:enable redundantSendable
