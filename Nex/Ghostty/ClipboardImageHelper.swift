import AppKit
import Foundation

/// Helpers for clipboard image paste — extracting image data from the
/// pasteboard and writing it to a temp PNG file.
enum ClipboardImageHelper {
    /// If the general pasteboard contains image data (PNG or TIFF),
    /// writes it to a temp PNG file and returns the file path.
    /// Returns nil if no image data is found or if writing fails.
    static func saveClipboardImageToTempFile() -> String? {
        let pasteboard = NSPasteboard.general

        let pngData: Data?
        if let data = pasteboard.data(forType: .png) {
            pngData = data
        } else if let data = pasteboard.data(forType: .tiff),
                  let imageRep = NSBitmapImageRep(data: data) {
            pngData = imageRep.representation(using: .png, properties: [:])
        } else {
            return nil
        }

        guard let pngData, !pngData.isEmpty else { return nil }

        let dir = NSTemporaryDirectory() + "nex-clipboard-images"
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let filename = "clipboard-\(UUID().uuidString).png"
        let filePath = (dir as NSString).appendingPathComponent(filename)

        do {
            try pngData.write(to: URL(fileURLWithPath: filePath), options: .atomic)
            return filePath
        } catch {
            return nil
        }
    }
}
