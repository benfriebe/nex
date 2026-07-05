import AppKit
@testable import Nex
import Testing

struct WindowFrameClampTests {
    /// A typical single-display arrangement.
    private let mainScreen = NSRect(x: 0, y: 0, width: 1920, height: 1080)

    @Test func frameFullyOnScreenIsUnchanged() {
        let frame = NSRect(x: 100, y: 100, width: 1200, height: 800)
        let result = WindowFrameClamp.constrained(
            frame,
            toVisible: [mainScreen],
            fallback: mainScreen
        )
        #expect(result == frame)
    }

    @Test func frameOnSecondDisplayIsUnchanged() {
        // Window saved on an external monitor to the right.
        let external = NSRect(x: 1920, y: 0, width: 2560, height: 1440)
        let frame = NSRect(x: 2000, y: 200, width: 1000, height: 700)
        let result = WindowFrameClamp.constrained(
            frame,
            toVisible: [mainScreen, external],
            fallback: mainScreen
        )
        #expect(result == frame)
    }

    @Test func offscreenFrameIsRecentredOnFallback() {
        // Frame saved on a now-disconnected left display (negative X), only
        // the main screen remains.
        let frame = NSRect(x: -1800, y: 100, width: 1200, height: 800)
        let result = WindowFrameClamp.constrained(
            frame,
            toVisible: [mainScreen],
            fallback: mainScreen
        )
        #expect(result.width == 1200)
        #expect(result.height == 800)
        #expect(result.midX == mainScreen.midX)
        #expect(result.midY == mainScreen.midY)
    }

    @Test func sliverOverlapBelowThresholdIsRecentred() {
        // Only a 10pt strip of the window remains on screen -- too little to
        // grab, so treat it as off-screen.
        let frame = NSRect(x: 1910, y: 500, width: 1200, height: 800)
        let result = WindowFrameClamp.constrained(
            frame,
            toVisible: [mainScreen],
            fallback: mainScreen
        )
        #expect(result.midX == mainScreen.midX)
        #expect(result.midY == mainScreen.midY)
    }

    @Test func overlapAtThresholdIsKept() {
        // Exactly minVisible on both axes counts as reachable.
        let frame = NSRect(
            x: 1920 - WindowFrameClamp.minVisible,
            y: 1080 - WindowFrameClamp.minVisible,
            width: 1200,
            height: 800
        )
        let result = WindowFrameClamp.constrained(
            frame,
            toVisible: [mainScreen],
            fallback: mainScreen
        )
        #expect(result == frame)
    }

    @Test func frameLargerThanFallbackIsShrunkToFit() {
        // Off-screen frame bigger than the only remaining display.
        let frame = NSRect(x: -5000, y: -5000, width: 3000, height: 2000)
        let result = WindowFrameClamp.constrained(
            frame,
            toVisible: [mainScreen],
            fallback: mainScreen
        )
        #expect(result.width == mainScreen.width)
        #expect(result.height == mainScreen.height)
        #expect(result.midX == mainScreen.midX)
        #expect(result.midY == mainScreen.midY)
    }

    @Test func noScreensRecentresOnFallback() {
        let frame = NSRect(x: 100, y: 100, width: 1200, height: 800)
        let result = WindowFrameClamp.constrained(
            frame,
            toVisible: [],
            fallback: mainScreen
        )
        #expect(result.midX == mainScreen.midX)
        #expect(result.midY == mainScreen.midY)
    }
}
