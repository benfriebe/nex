import Foundation
@testable import Nex
import Testing

struct TitlebarDoubleClickActionTests {
    @Test func maximizeResolvesToZoom() {
        #expect(TitlebarDoubleClickAction.resolve(from: "Maximize") == .zoom)
    }

    @Test func minimizeResolvesToMinimize() {
        #expect(TitlebarDoubleClickAction.resolve(from: "Minimize") == .minimize)
    }

    @Test func noneResolvesToDoNothing() {
        #expect(TitlebarDoubleClickAction.resolve(from: "None") == .doNothing)
    }

    @Test func nilDefaultsToZoom() {
        // Unset preference: macOS factory default is Zoom.
        #expect(TitlebarDoubleClickAction.resolve(from: nil) == .zoom)
    }

    @Test func unknownValueDefaultsToZoom() {
        #expect(TitlebarDoubleClickAction.resolve(from: "Fill") == .zoom)
        #expect(TitlebarDoubleClickAction.resolve(from: "") == .zoom)
    }
}
