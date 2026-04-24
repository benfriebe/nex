import SwiftUI

/// Editable plain-text view for markdown files, wrapping NSTextView.
struct MarkdownEditorView: NSViewRepresentable {
    let paneID: UUID
    let filePath: String
    let isFocused: Bool
    var backgroundColor: NSColor = .textBackgroundColor
    var backgroundOpacity: Double = 1.0
    @Environment(\.sidebarTextEditingActive) private var sidebarTextEditingActive

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PaneFocusView {
        let container = PaneFocusView(paneID: paneID)

        let textView = FocusNotifyingTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.usesFindBar = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor.textColor
        textView.backgroundColor = backgroundColor.withAlphaComponent(backgroundOpacity)
        textView.insertionPointColor = NSColor.textColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = backgroundColor.withAlphaComponent(backgroundOpacity)

        // Line number gutter
        scrollView.rulersVisible = true
        let rulerView = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = rulerView

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.rulerView = rulerView
        context.coordinator.paneID = paneID
        context.coordinator.filePath = filePath
        context.coordinator.loadFile()
        context.coordinator.restoreScrollFraction()
        textView.delegate = context.coordinator

        // Track scroll position changes
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        container.embed(scrollView)

        if isFocused, !sidebarTextEditingActive {
            claimFirstResponder(textView)
        }
        context.coordinator.lastIsFocused = isFocused
        return container
    }

    func updateNSView(_: PaneFocusView, context: Context) {
        if context.coordinator.filePath != filePath {
            context.coordinator.filePath = filePath
            context.coordinator.loadFile()
        }
        // Only claim on a real false→true transition so re-renders caused
        // by unrelated state changes (e.g., the user typing in the command
        // palette's TextField) don't yank first responder back.
        if isFocused, !context.coordinator.lastIsFocused, !sidebarTextEditingActive,
           let textView = context.coordinator.textView {
            claimFirstResponder(textView)
        }
        context.coordinator.lastIsFocused = isFocused
    }

    private func claimFirstResponder(_ textView: NSTextView) {
        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window else { return }
            if window.firstResponder === textView { return }
            window.makeFirstResponder(textView)
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var textView: NSTextView?
        var scrollView: NSScrollView?
        var rulerView: LineNumberRulerView?
        var paneID: UUID?
        var filePath: String = ""
        var lastIsFocused: Bool = false
        private var saveTask: Task<Void, Never>?

        func loadFile() {
            guard !filePath.isEmpty else { return }
            do {
                let content = try String(contentsOfFile: filePath, encoding: .utf8)
                textView?.string = content
            } catch {
                textView?.string = "// Failed to load: \(error.localizedDescription)"
            }
            rulerView?.invalidateLineCount()
        }

        func restoreScrollFraction() {
            guard let paneID,
                  let fraction = PaneFocusView.scrollFraction(for: paneID),
                  fraction > 0,
                  let scrollView,
                  scrollView.documentView != nil else { return }
            // Defer so layout has completed
            DispatchQueue.main.async { [weak self] in
                guard let scrollView = self?.scrollView,
                      let documentView = scrollView.documentView else { return }
                let maxScroll = documentView.frame.height - scrollView.contentSize.height
                if maxScroll > 0 {
                    let y = fraction * maxScroll
                    documentView.scroll(NSPoint(x: 0, y: y))
                }
            }
        }

        @objc func scrollViewDidScroll(_: Notification) {
            rulerView?.needsDisplay = true
            guard let paneID, let scrollView, let documentView = scrollView.documentView else { return }
            let maxScroll = documentView.frame.height - scrollView.contentSize.height
            guard maxScroll > 0 else { return }
            let fraction = scrollView.contentView.bounds.origin.y / maxScroll
            PaneFocusView.saveScrollFraction(fraction, for: paneID)
        }

        @preconcurrency
        func textDidChange(_: Notification) {
            rulerView?.invalidateLineCount()
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.writeToDisk()
            }
        }

        private func writeToDisk() {
            guard !filePath.isEmpty, let content = textView?.string else { return }
            do {
                try content.write(toFile: filePath, atomically: true, encoding: .utf8)
            } catch {
                print("MarkdownEditorView: save failed — \(error)")
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
