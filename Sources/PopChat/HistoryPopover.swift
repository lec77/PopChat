import SwiftUI

/// Recent-conversations popover, anchored off the clock pill. Type-to-filter,
/// day-group headers, hover-to-delete (trash click or ⌘⌫).
struct HistoryPopover: View {
    @ObservedObject var store: ChatStore
    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @Environment(\.dismiss) private var dismiss

    @State private var filter = ""
    @State private var hoveredID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Filter chats…", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if filtered.isEmpty {
                Text(store.recent.isEmpty ? "No saved chats" : "No matches")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(groups) { group in
                            Text(group.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.primary.opacity(0.4))
                                .textCase(.uppercase)
                                .padding(.horizontal, 8)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                            ForEach(group.items) { meta in
                                row(meta)
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 380)
            }
        }
        .frame(width: 300)
    }

    private func row(_ meta: ConversationMeta) -> some View {
        let isCurrent = meta.id == store.conversationID
        let isHovered = hoveredID == meta.id
        return Button {
            store.loadConversation(meta.id)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(meta.title)
                        .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if isHovered {
                        Button {
                            store.deleteConversation(meta.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.delete, modifiers: .command)
                        .help("Delete chat (⌘⌫)")
                    } else if isCurrent {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.color(accentHex))
                    }
                    Text(timestamp(meta.updatedAt))
                        .font(.system(size: 10))
                        .foregroundStyle(.primary.opacity(0.45))
                }
                if !meta.snippet.isEmpty {
                    Text(meta.snippet)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.55))
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .background(
                isCurrent ? Theme.color(accentHex).opacity(0.16)
                    : isHovered ? Color.primary.opacity(0.06)
                    : .clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hoveredID = meta.id
            } else if hoveredID == meta.id {
                hoveredID = nil
            }
        }
    }

    // MARK: - Grouping

    private var filtered: [ConversationMeta] {
        guard !filter.isEmpty else { return store.recent }
        return store.recent.filter {
            $0.title.localizedCaseInsensitiveContains(filter)
                || $0.snippet.localizedCaseInsensitiveContains(filter)
        }
    }

    private struct DayGroup: Identifiable {
        let id: String
        let title: String
        var items: [ConversationMeta]
    }

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        var result: [DayGroup] = []
        for meta in filtered {
            let day = calendar.startOfDay(for: meta.updatedAt)
            let key = day.formatted(.iso8601.year().month().day())
            if result.last?.id == key {
                result[result.count - 1].items.append(meta)
            } else {
                result.append(DayGroup(id: key, title: groupTitle(for: meta.updatedAt, calendar: calendar), items: [meta]))
            }
        }
        return result
    }

    private func groupTitle(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: .now)),
           date >= weekAgo {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func timestamp(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
