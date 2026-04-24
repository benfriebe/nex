import AppKit

/// NSTextView that posts `SurfaceView.paneFocusedNotification` when it
/// becomes first responder. Needed because NSTextView consumes primary
/// mouse clicks to position its cursor, which prevents the click gesture
/// recognizer attached to the enclosing `PaneFocusView`'s child from
/// firing. Without this, clicking directly into the scratchpad or
/// markdown editor text area would not update the pane focus state,
/// unlike clicking the pane header or the line-number gutter.
///
/// The enclosing `PaneFocusView` is discovered via the superview chain so
/// callers don't have to wire the paneID manually.
final class FocusNotifyingTextView: NSTextView {
    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome, let paneID = enclosingPaneFocusView?.paneID {
            NotificationCenter.default.post(
                name: SurfaceView.paneFocusedNotification,
                object: nil,
                userInfo: ["paneID": paneID]
            )
        }
        return didBecome
    }

    private var enclosingPaneFocusView: PaneFocusView? {
        var view: NSView? = superview
        while let current = view {
            if let container = current as? PaneFocusView { return container }
            view = current.superview
        }
        return nil
    }
}
