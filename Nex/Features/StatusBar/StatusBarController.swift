import AppKit
import ComposableArchitecture
import SwiftUI

struct StatusBarItem: Equatable, Identifiable {
    let workspaceName: String
    let workspaceColor: WorkspaceColor
    let paneTitle: String
    let paneID: UUID
    let workspaceID: UUID
    let status: PaneStatus

    var id: UUID { paneID }
}

final class StatusBarController: NSObject, @unchecked Sendable {
    private nonisolated(unsafe) var statusItem: NSStatusItem?
    private nonisolated(unsafe) var popover: NSPopover?
    private nonisolated(unsafe) var eventMonitor: Any?

    private nonisolated(unsafe) var waitingCount: Int = 0
    private nonisolated(unsafe) var runningCount: Int = 0
    private nonisolated(unsafe) var items: [StatusBarItem] = []

    nonisolated(unsafe) var onSelectPane: ((UUID, UUID) -> Void)?

    @MainActor
    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item
        updateIcon()
    }

    @MainActor
    func update(waitingCount: Int, runningCount: Int, items: [StatusBarItem]) {
        self.waitingCount = waitingCount
        self.runningCount = runningCount
        self.items = items
        updateIcon()

        // Update popover content if visible
        if let popover, popover.isShown {
            updatePopoverContent()
        }
    }

    // MARK: - Icon Drawing

    @MainActor
    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let size = NSSize(width: 18, height: 18)
        let waiting = waitingCount
        let running = runningCount

        let image = NSImage(size: size, flipped: false) { rect in
            // Draw terminal icon
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            if let symbol = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Nex")?
                .withSymbolConfiguration(symbolConfig) {
                let symbolSize = symbol.size
                let origin = NSPoint(
                    x: (rect.width - symbolSize.width) / 2,
                    y: (rect.height - symbolSize.height) / 2
                )
                symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
            }

            // Draw overlay dot
            if waiting > 0 {
                let dotSize: CGFloat = 6
                let dotRect = NSRect(
                    x: rect.width - dotSize - 1,
                    y: rect.height - dotSize - 1,
                    width: dotSize,
                    height: dotSize
                )
                NSColor.systemBlue.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            } else if running > 0 {
                let dotSize: CGFloat = 6
                let dotRect = NSRect(
                    x: rect.width - dotSize - 1,
                    y: rect.height - dotSize - 1,
                    width: dotSize,
                    height: dotSize
                )
                NSColor.systemGreen.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }

            return true
        }
        image.isTemplate = waiting == 0 && running == 0
        button.image = image
    }

    // MARK: - Popover

    @objc private func togglePopover(_: Any?) {
        MainActor.assumeIsolated {
            if let popover, popover.isShown {
                popover.performClose(nil)
                removeEventMonitor()
            } else {
                showPopover()
            }
        }
    }

    @MainActor
    private func showPopover() {
        guard let button = statusItem?.button else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        updatePopoverContent(popover: popover)

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = popover

        // Close popover when clicking outside
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover?.performClose(nil)
            self?.removeEventMonitor()
        }
    }

    @MainActor
    private func updatePopoverContent(popover: NSPopover? = nil) {
        let target = popover ?? self.popover
        let currentItems = items
        let callback = onSelectPane
        let hostingView = NSHostingView(
            rootView: StatusBarPopoverView(items: currentItems) { paneID, workspaceID in
                callback?(paneID, workspaceID)
                target?.performClose(nil)
            }
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 280, height: max(60, min(400, CGFloat(currentItems.count) * 48 + 44)))
        let viewController = NSViewController()
        viewController.view = hostingView
        target?.contentViewController = viewController
    }

    @MainActor
    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

// MARK: - TCA Dependency

extension StatusBarController: DependencyKey {
    static let liveValue = StatusBarController()
    static let testValue = StatusBarController()
}

extension DependencyValues {
    var statusBarController: StatusBarController {
        get { self[StatusBarController.self] }
        set { self[StatusBarController.self] = newValue }
    }
}
