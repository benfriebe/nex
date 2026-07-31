import SwiftUI

/// One field per declared input, shown before launching a run. Skipped
/// entirely by the caller when the definition has no inputs — tapping
/// Run goes straight to `onRun([:])`.
struct RunPipelineSheet: View {
    let definition: PipelineDefinition
    let onRun: ([String: String]) -> Void
    let onCancel: () -> Void

    @State private var values: [String: String] = [:]
    @Environment(\.chromeTheme) private var chromeTheme

    private var sortedInputs: [(key: String, spec: PipelineInputSpec)] {
        definition.inputs.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private var missingRequired: [String] {
        sortedInputs
            .filter(\.spec.required)
            .map(\.key)
            .filter { (values[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Run \(definition.name)")
                .font(.system(size: 14, weight: .semibold))

            ForEach(sortedInputs, id: \.key) { key, spec in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(key)
                            .font(.system(size: 12, weight: .medium))
                        if spec.required {
                            Text("*").foregroundStyle(.red)
                        }
                    }
                    if let description = spec.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 10))
                            .foregroundStyle(chromeTheme.textSecondary)
                    }
                    TextField(
                        "",
                        text: Binding(
                            get: { values[key] ?? "" },
                            set: { values[key] = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Run") { onRun(values) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!missingRequired.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 340)
    }
}
