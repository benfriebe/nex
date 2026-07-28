import SwiftUI

/// Trailing inspector panel — node or edge fields, depending on
/// `PipelinePaneState.selection`. Inline (not a popover/sheet) since the
/// prompt field is a multiline `TextEditor`.
struct PipelineInspectorView: View {
    let document: PipelineDefinition
    let selection: PipelineCanvasSelection
    let onEdit: (PipelineEdit) -> Void
    let onDeleteSelection: () -> Void
    let onSetEntry: (String) -> Void

    @Environment(\.chromeTheme) private var chromeTheme
    @State private var newEdgeTarget: String?
    @State private var newEdgeOutcome: PipelineNodeOutcome = .done

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch selection {
                case let .node(id):
                    if let node = document.nodes.first(where: { $0.id == id }) {
                        nodeFields(node)
                    }
                case let .edge(index):
                    if document.edges.indices.contains(index) {
                        edgeFields(document.edges[index], index: index)
                    }
                case .none:
                    Text("Select a node or edge to edit its properties.")
                        .font(.system(size: 12))
                        .foregroundStyle(chromeTheme.textSecondary)
                        .padding(.top, 24)
                }
            }
            .padding(12)
        }
        .frame(width: 280)
        .background(chromeTheme.headerBackground)
    }

    @ViewBuilder
    private func nodeFields(_ node: PipelineNode) -> some View {
        sectionHeader("Node · \(node.id)")

        labeledField("Name") {
            TextField("Display name", text: Binding(
                get: { node.name ?? "" },
                set: { onEdit(.updateNodeName(id: node.id, name: $0)) }
            ))
            .textFieldStyle(.roundedBorder)
        }

        labeledField("Agent") {
            Picker("Agent", selection: Binding(
                get: { node.agent },
                set: { onEdit(.updateNodeAgent(id: node.id, agent: $0)) }
            )) {
                Text("claude").tag(AgentKind.claude)
                Text("codex (not supported in v1)").tag(AgentKind.codex)
            }
            .labelsHidden()
        }

        labeledField("Model") {
            TextField("e.g. opus", text: Binding(
                get: { node.model ?? "" },
                set: { onEdit(.updateNodeModel(id: node.id, model: $0)) }
            ))
            .textFieldStyle(.roundedBorder)
        }

        labeledField("Mode") {
            Picker("Mode", selection: Binding(
                get: { node.mode },
                set: { onEdit(.updateNodeMode(id: node.id, mode: $0)) }
            )) {
                Text("headless").tag(PipelineNodeMode.headless)
                Text("interactive").tag(PipelineNodeMode.interactive)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        labeledField("Permission mode") {
            Picker("Permission mode", selection: Binding(
                get: { node.permissionMode },
                set: { onEdit(.updateNodePermissionMode(id: node.id, mode: $0)) }
            )) {
                ForEach(PipelinePermissionMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
        }

        labeledField("Prompt") {
            TextEditor(text: Binding(
                get: { node.prompt },
                set: { onEdit(.updateNodePrompt(id: node.id, prompt: $0)) }
            ))
            .font(.system(size: 12, design: .monospaced))
            .frame(minHeight: 160)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(chromeTheme.divider))
        }

        if node.id != document.entry {
            Button("Set as entry node") { onSetEntry(node.id) }
                .font(.system(size: 11))
        }

        Divider()
        addEdgeSection(from: node)

        Divider()
        Button(role: .destructive) { onDeleteSelection() } label: {
            Label("Delete node", systemImage: "trash")
        }
        .font(.system(size: 11))
    }

    /// Edges are created here rather than by dragging from a port on the
    /// canvas (deferred — see the pipeline panes doc in CLAUDE.md).
    @ViewBuilder
    private func addEdgeSection(from node: PipelineNode) -> some View {
        let candidates = document.nodes.filter { $0.id != node.id }
        sectionHeader("Add edge")

        if candidates.isEmpty {
            Text("Add another node first.")
                .font(.system(size: 11))
                .foregroundStyle(chromeTheme.textTertiary)
        } else {
            let target = newEdgeTarget.flatMap { id in candidates.first { $0.id == id } } ?? candidates[0]
            let alreadyExists = document.edges.contains { $0.from == node.id && $0.on == newEdgeOutcome }

            labeledField("On outcome") {
                Picker("On outcome", selection: $newEdgeOutcome) {
                    ForEach(PipelineNodeOutcome.allCases, id: \.self) { outcome in
                        Text(outcome.rawValue).tag(outcome)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            labeledField("Go to") {
                Picker("Go to", selection: Binding(
                    get: { target.id },
                    set: { newEdgeTarget = $0 }
                )) {
                    ForEach(candidates) { candidate in
                        Text(candidate.displayName).tag(candidate.id)
                    }
                }
                .labelsHidden()
            }

            Button {
                onEdit(.addEdge(from: node.id, on: newEdgeOutcome, to: target.id))
            } label: {
                Label("Add edge", systemImage: "arrow.turn.right.down")
            }
            .font(.system(size: 11))
            .disabled(alreadyExists)

            if alreadyExists {
                Text("An edge for \"\(newEdgeOutcome.rawValue)\" already exists from this node.")
                    .font(.system(size: 10))
                    .foregroundStyle(chromeTheme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func edgeFields(_ edge: PipelineEdge, index: Int) -> some View {
        sectionHeader("Edge · \(edge.from) → \(edge.to)")

        labeledField("Outcome") {
            Picker("Outcome", selection: Binding(
                get: { edge.on },
                set: { onEdit(.updateEdgeOutcome(index: index, outcome: $0)) }
            )) {
                ForEach(PipelineNodeOutcome.allCases, id: \.self) { outcome in
                    Text(outcome.rawValue).tag(outcome)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        labeledField("Max traversals") {
            Stepper(
                value: Binding(
                    get: { edge.maxTraversals ?? 0 },
                    set: { onEdit(.updateEdgeMaxTraversals(index: index, value: $0 == 0 ? nil : $0)) }
                ),
                in: 0 ... 20
            ) {
                Text(edge.maxTraversals.map { "\($0)" } ?? "Unlimited")
                    .font(.system(size: 11))
            }
        }

        Toggle("Requires approval", isOn: Binding(
            get: { edge.requiresApproval },
            set: { onEdit(.updateEdgeRequiresApproval(index: index, value: $0)) }
        ))
        .font(.system(size: 12))

        Divider()
        Button(role: .destructive) { onDeleteSelection() } label: {
            Label("Delete edge", systemImage: "trash")
        }
        .font(.system(size: 11))
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(chromeTheme.textPrimary)
    }

    private func labeledField(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(chromeTheme.textTertiary)
            content()
        }
    }
}
