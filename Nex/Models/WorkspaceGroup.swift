import Foundation

struct WorkspaceGroup: Equatable, Identifiable, Codable {
    let id: UUID
    var name: String
    var color: WorkspaceColor?
    var isCollapsed: Bool
    var childOrder: [UUID]
    var createdAt: Date
    /// Optional icon override for the group header. `nil` falls back
    /// to the colour-tinted folder glyph.
    var icon: GroupIcon?

    init(
        id: UUID = UUID(),
        name: String,
        color: WorkspaceColor? = nil,
        isCollapsed: Bool = false,
        childOrder: [UUID] = [],
        createdAt: Date = Date(),
        icon: GroupIcon? = nil
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
        self.childOrder = childOrder
        self.createdAt = createdAt
        self.icon = icon
    }
}

/// Pending "Delete Group?" confirmation. `workspaceCount` is captured when the
/// prompt is shown so the UI can display it without reaching back into state.
struct GroupDeleteConfirmation: Equatable {
    let groupID: UUID
    let groupName: String
    let workspaceCount: Int
}

/// Pending "Group Selected Workspaces..." prompt, captured alongside the
/// selection to use when the user confirms.
struct GroupBulkCreatePrompt: Equatable {
    let workspaceIDs: [UUID]
}

/// Pending "Custom Emoji…" sheet for a group. Stores the target group
/// so the confirm action can write the chosen emoji back without
/// relying on external focus state.
struct GroupCustomEmojiPrompt: Equatable {
    let groupID: UUID
    let groupName: String
}
