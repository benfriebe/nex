import Foundation
@testable import Nex
import Testing
import WebKit

/// Hidden WKWebView preloaded with `WebPaneActuatorScript` as a
/// document-start user script. Tests load HTML via `loadHTMLString`,
/// wait for navigation completion, then run JS against the resulting
/// document. Shared by the selector and action-verb test suites.
@MainActor
final class ActuatorTestHost: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var didFinish: CheckedContinuation<Void, Error>?

    static func make(html: String) async throws -> ActuatorTestHost {
        let host = ActuatorTestHost()
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

    /// Evaluate `js` and coerce the result to `String`, returning ""
    /// on non-string results. Used by tests that wrap the JS call in
    /// `JSON.stringify(...)` to inspect a reply envelope.
    func evalString(_ js: String) async throws -> String {
        try await (eval(js) as? String) ?? ""
    }

    /// `callAsyncJavaScript` wraps `js` in `async function(){ ... }`
    /// and awaits any returned Promise, so the resolved value is
    /// what comes back. Required for testing actuator methods that
    /// return Promises (`wait`).
    func evalAsync(_ js: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(
            js, arguments: [:], in: nil, contentWorld: .page
        )
    }

    /// Convenience: `callAsyncJavaScript` returning a JSON-encoded
    /// string. Combine with `parse(_:)` to inspect a reply envelope.
    func evalAsyncString(_ js: String) async throws -> String {
        try await (evalAsync(js) as? String) ?? ""
    }

    /// Parse a JSON object string produced by `JSON.stringify(...)`
    /// on the JS side. Throws (with the raw string in the message) if
    /// the input isn't a valid JSON object.
    func parse(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw NSError(domain: "ActuatorTestHost", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "not a JSON object: \(json)"
            ])
        }
        return parsed
    }

    private nonisolated func complete(_ result: Result<Void, Error>) {
        Task { @MainActor in
            switch result {
            case .success:
                self.didFinish?.resume()
            case .failure(let error):
                self.didFinish?.resume(throwing: error)
            }
            self.didFinish = nil
        }
    }

    nonisolated func webView(_: WKWebView, didFinish _: WKNavigation!) {
        complete(.success(()))
    }

    nonisolated func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        complete(.failure(error))
    }

    nonisolated func webView(
        _: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error
    ) {
        complete(.failure(error))
    }
}
