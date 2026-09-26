//
//  ChatHistorySidebar.swift
//  Wanda
//

import SwiftUI

/// Saved chats, newest first, grouped by day. Click to open; rename or delete from the
/// "…" button, the right-click menu, or double-click a title to rename it.
struct ChatHistorySidebar: View {
    @ObservedObject var store: ChatStore
    let currentID: UUID?
    let onSelect: (UUID) -> Void
    let onNewChat: () -> Void
    let onRename: (UUID, String) -> Void
    let onDelete: (UUID) -> Void

    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var hoveredID: UUID?
    @State private var pendingDelete: Conversation?
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Chats")
                    .font(.headline)
                Spacer()
                Button(action: onNewChat) {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("New chat")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if store.conversations.isEmpty {
                Text("Your chats will appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(sections, id: \.title) { section in
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.top, 10)
                                .padding(.bottom, 2)
                            ForEach(section.conversations) { conversation in
                                row(conversation)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
            }
        }
        .background(Color.primary.opacity(0.03))
        .confirmationDialog(
            "Delete “\(pendingDelete?.title ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { conversation in
            Button("Delete", role: .destructive) { onDelete(conversation.id) }
        } message: { _ in
            Text("This chat will be removed from Wanda. This can't be undone.")
        }
    }

    @ViewBuilder
    private func row(_ conversation: Conversation) -> some View {
        let isSelected = conversation.id == currentID
        let isHovered = conversation.id == hoveredID
        HStack(spacing: 4) {
            if renamingID == conversation.id {
                TextField("Chat name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .focused($renameFieldFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { renamingID = nil }
                    .onChange(of: renameFieldFocused) { focused in
                        if !focused { commitRename() }
                    }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(conversation.title)
                        .lineLimit(1)
                    Text(conversation.updatedAt, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isHovered || isSelected {
                    Menu {
                        actions(for: conversation)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Rename or delete")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            isSelected ? Color.accentColor.opacity(0.22) : (isHovered ? Color.primary.opacity(0.07) : .clear),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startRename(conversation) }
        .onTapGesture { onSelect(conversation.id) }
        .onHover { hovering in hoveredID = hovering ? conversation.id : (hoveredID == conversation.id ? nil : hoveredID) }
        .contextMenu { actions(for: conversation) }
    }

    @ViewBuilder
    private func actions(for conversation: Conversation) -> some View {
        Button("Rename") { startRename(conversation) }
        Button("Delete…", role: .destructive) { pendingDelete = conversation }
    }

    private func startRename(_ conversation: Conversation) {
        renameText = conversation.title
        renamingID = conversation.id
        renameFieldFocused = true
    }

    private func commitRename() {
        guard let id = renamingID else { return }
        onRename(id, renameText)
        renamingID = nil
    }

    private var sections: [(title: String, conversations: [Conversation])] {
        let calendar = Calendar.current
        var today: [Conversation] = [], yesterday: [Conversation] = [], week: [Conversation] = [], older: [Conversation] = []
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        for conversation in store.conversations {
            if calendar.isDateInToday(conversation.updatedAt) {
                today.append(conversation)
            } else if calendar.isDateInYesterday(conversation.updatedAt) {
                yesterday.append(conversation)
            } else if conversation.updatedAt > weekAgo {
                week.append(conversation)
            } else {
                older.append(conversation)
            }
        }
        return [("Today", today), ("Yesterday", yesterday), ("Previous 7 days", week), ("Older", older)]
            .filter { !$0.1.isEmpty }
    }
}
