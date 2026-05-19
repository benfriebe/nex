import Foundation
@testable import Nex
import Testing

struct WebPaneURLNormalisationTests {
    @Test func emptyInputReturnsEmpty() {
        #expect(WebPaneCoordinator.normalizeURLInput("") == "")
        #expect(WebPaneCoordinator.normalizeURLInput("   ") == "")
    }

    @Test func passesThroughExplicitHTTPSchemes() {
        #expect(WebPaneCoordinator.normalizeURLInput("https://example.com") == "https://example.com")
        #expect(WebPaneCoordinator.normalizeURLInput("http://example.com/path?q=1") == "http://example.com/path?q=1")
    }

    @Test func passesThroughOpaqueSchemes() {
        // Without the scheme-detection rule, these would get an
        // erroneous `https://` prefix and never load.
        #expect(
            WebPaneCoordinator.normalizeURLInput("data:text/html,<h1>x</h1>")
                == "data:text/html,<h1>x</h1>"
        )
        #expect(
            WebPaneCoordinator.normalizeURLInput("javascript:void(0)")
                == "javascript:void(0)"
        )
        #expect(
            WebPaneCoordinator.normalizeURLInput("mailto:foo@bar.com")
                == "mailto:foo@bar.com"
        )
        #expect(
            WebPaneCoordinator.normalizeURLInput("tel:+61400000000")
                == "tel:+61400000000"
        )
        #expect(
            WebPaneCoordinator.normalizeURLInput("about:blank")
                == "about:blank"
        )
        #expect(
            WebPaneCoordinator.normalizeURLInput("file:///tmp/page.html")
                == "file:///tmp/page.html"
        )
    }

    @Test func bareHostnameGetsHTTPSPrefix() {
        #expect(WebPaneCoordinator.normalizeURLInput("example.com") == "https://example.com")
        #expect(WebPaneCoordinator.normalizeURLInput("www.example.com/path") == "https://www.example.com/path")
    }

    @Test func localHostnameGetsHTTPPrefix() {
        // Local + private addresses fall back to http://. Single-label
        // host (no dot) is also treated as internal.
        #expect(WebPaneCoordinator.normalizeURLInput("localhost") == "http://localhost")
        #expect(WebPaneCoordinator.normalizeURLInput("localhost:3000") == "http://localhost:3000")
        #expect(WebPaneCoordinator.normalizeURLInput("127.0.0.1:8080") == "http://127.0.0.1:8080")
        #expect(WebPaneCoordinator.normalizeURLInput("router.local") == "http://router.local")
        #expect(WebPaneCoordinator.normalizeURLInput("dev-box") == "http://dev-box")
    }

    @Test func hostPortPairIsNotMistakenForAScheme() {
        // `host:port` (digits after colon) should NOT be treated as a
        // scheme — must still get the http/https prefix.
        #expect(WebPaneCoordinator.normalizeURLInput("example.com:8080") == "https://example.com:8080")
        #expect(WebPaneCoordinator.normalizeURLInput("localhost:3000") == "http://localhost:3000")
    }

    @Test func privateRangesGetHTTPPrefix() {
        #expect(WebPaneCoordinator.normalizeURLInput("10.0.0.1") == "http://10.0.0.1")
        #expect(WebPaneCoordinator.normalizeURLInput("192.168.1.1") == "http://192.168.1.1")
        #expect(WebPaneCoordinator.normalizeURLInput("172.16.0.1") == "http://172.16.0.1")
        #expect(WebPaneCoordinator.normalizeURLInput("169.254.1.1") == "http://169.254.1.1")
    }
}
