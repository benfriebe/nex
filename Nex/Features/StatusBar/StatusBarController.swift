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

/// One active (non-terminal) pipeline run, surfaced in the "Pipelines"
/// popover section (issue #282 phase 7).
struct StatusBarPipelineItem: Equatable, Identifiable {
    let runID: UUID
    let name: String
    let status: PipelineRunStatus
    let currentNodeID: String?
    let createdAt: Date

    var id: UUID { runID }
}

final class StatusBarController: NSObject, @unchecked Sendable {
    private nonisolated(unsafe) var statusItem: NSStatusItem?
    private nonisolated(unsafe) var popover: NSPopover?
    private nonisolated(unsafe) var eventMonitor: Any?

    private nonisolated(unsafe) var waitingCount: Int = 0
    private nonisolated(unsafe) var runningCount: Int = 0
    private nonisolated(unsafe) var items: [StatusBarItem] = []
    private nonisolated(unsafe) var pipelineItems: [StatusBarPipelineItem] = []
    // Configurable agent-status colours, resolved from the chrome theme. The
    // menu-bar dot and the popover use these instead of system blue/green so
    // they match the in-app status colours.
    private nonisolated(unsafe) var waitingColor: Color = .blue
    private nonisolated(unsafe) var runningColor: Color = .green

    nonisolated(unsafe) var onSelectPane: ((UUID, UUID) -> Void)?
    /// Click a "Pipelines" section row — focuses the run's current node
    /// pane (or just its workspace, if nothing has spawned yet).
    nonisolated(unsafe) var onSelectPipeline: ((UUID) -> Void)?

    @MainActor
    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item
        updateIcon()
    }

    @MainActor
    func update(
        waitingCount: Int,
        runningCount: Int,
        items: [StatusBarItem],
        pipelineItems: [StatusBarPipelineItem] = [],
        waitingColor: Color = .blue,
        runningColor: Color = .green
    ) {
        self.waitingCount = waitingCount
        self.runningCount = runningCount
        self.items = items
        self.pipelineItems = pipelineItems
        self.waitingColor = waitingColor
        self.runningColor = runningColor
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
        let waitingFill = waitingColor
        let runningFill = runningColor

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
                NSColor(waitingFill).setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            } else if running > 0 {
                let dotSize: CGFloat = 6
                let dotRect = NSRect(
                    x: rect.width - dotSize - 1,
                    y: rect.height - dotSize - 1,
                    width: dotSize,
                    height: dotSize
                )
                NSColor(runningFill).setFill()
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
        let currentPipelineItems = pipelineItems
        let callback = onSelectPane
        let pipelineCallback = onSelectPipeline
        let hostingView = NSHostingView(
            rootView: StatusBarPopoverView(
                items: currentItems,
                pipelineItems: currentPipelineItems,
                waitingColor: waitingColor,
                runningColor: runningColor,
                onSelectPane: { paneID, workspaceID in
                    callback?(paneID, workspaceID)
                    target?.performClose(nil)
                },
                onSelectPipeline: { runID in
                    pipelineCallback?(runID)
                    target?.performClose(nil)
                }
            )
        )
        hostingView.frame = NSRect(
            x: 0, y: 0, width: 280,
            height: max(60, min(500, CGFloat(currentItems.count) * 48 + CGFloat(currentPipelineItems.count) * 40 + 64))
        )
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
