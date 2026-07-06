import AppKit
@testable import Nex
import Testing

struct WindowFrameClampTests {
    /// A typical single-display visible frame.
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

    @Test func topStripAboveScreenIsRecentred() {
        // Straddle-then-disconnect: window was on an external display ABOVE
        // the laptop; only its bottom edge overlaps the remaining screen, so
        // the titlebar/drag strip is above the top -- ungrabbable. Must
        // recenter even though there's a big overlap area.
        let frame = NSRect(x: 400, y: 1000, width: 1000, height: 700)
        let result = WindowFrameClamp.constrained(
            frame,
            toVisible: [mainScreen],
            fallback: mainScreen
        )
        #expect(result.midX == mainScreen.midX)
        #expect(result.midY == mainScreen.midY)
    }

    @Test func frameLargerThanDisplayIsShrunkAndRecentred() {
        // Saved on a 5K display, restored on a smaller one: too big to fit,
        // so even if the origin overlapped it must be shrunk to fit and
        // recentered so the whole window (incl. titlebar) is reachable.
        let frame = NSRect(x: 0, y: 0, width: 3000, height: 2000)
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

    @Test func cornerOnlyOverlapIsRecentred() {
        // Only the bottom-left corner sits on screen; the top strip is off to
        // the right and above -- not grabbable.
        let frame = NSRect(x: 1880, y: 1040, width: 1000, height: 700)
        let result = WindowFrameClamp.constrained(
            frame,
            toVisible: [mainScreen],
            fallback: mainScreen
        )
        #expect(result.midX == mainScreen.midX)
        #expect(result.midY == mainScreen.midY)
    }

    @Test func topStripReachableAtThresholdIsKept() {
        // The window's top strip sits fully on-screen with exactly minVisible
        // grabbable width at the right edge -- reachable, so keep it.
        let width: CGFloat = 1000
        let x = mainScreen.maxX - WindowFrameClamp.minVisible // 80pt of strip on screen
        // Keep the whole frame within the screen vertically so the top strip
        // (top dragStripHeight band) is fully on-screen.
        let frame = NSRect(x: x, y: 200, width: width, height: 700)
        let result = WindowFrameClamp.constrained(
            frame,
            toVisible: [mainScreen],
            fallback: mainScreen
        )
        #expect(result == frame)
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
