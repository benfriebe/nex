import SwiftUI

// MARK: - Data

enum HelpData {
    static let githubURL = URL(string: "https://github.com/benfriebe/nex")!

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }
}

// MARK: - Views

struct HelpView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Nex")
                            .font(.title.bold())
                        Text("Version \(HelpData.appVersion)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Keyboard shortcuts pointer
                Text("Keyboard Shortcuts")
                    .font(.title2.bold())

                HStack {
                    Text("View and customize all keyboard shortcuts in")
                    Button("Settings > Keybindings") {
                        openSettings()
                    }
                    .buttonStyle(.link)
                }

                Divider()

                // Links
                HStack {
                    Link("GitHub Repository", destination: HelpData.githubURL)
                    Spacer()
                }
            }
            .padding(24)
        }
        .frame(width: 420, height: 300)
    }
}
