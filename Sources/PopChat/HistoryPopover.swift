import SwiftUI

/// Recent-conversations popover, anchored off the clock pill (⌘Y). Type-to-filter,
/// ↑/↓ to select and ↩ to open, day-group headers, delete (trash click or ⌘⌫).
///
/// Delta 3 (5b/5c/5d): the sheet pops out of the clock pill with a row cascade
/// instead of the stock NSPopover fade, opens at its FINAL size (see `Metrics` —
/// a LazyVStack made NSPopover present at an estimated size and re-size
/// mid-animation, which against the 120pt empty panel is the whole show), and
/// dismisses on a designed curve BEFORE the panel starts growing.
struct HistoryPopover: View {
    @ObservedObject var store: ChatStore
    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var filter = ""
    @State private var hoveredID: UUID?
    /// Keyboard selection, independent of hover. Preselected so ↩ works the
    /// instant the popover opens.
    @State private var selectedID: UUID?
    @State private var filterFocusBump = 0
    /// Drives the whole designed presentation (5b): flipped true in onAppear for
    /// the pop-in, and back to false to run the out-animation before the popover
    /// itself closes.
    @State private var appeared = false
    /// Set once `close` is running, so the same `appeared` change animates on the
    /// dismiss curve with no row cascade.
    @State private var isClosing = false
    /// The row flashing accent under the press (5d), ahead of the dismiss.
    @State private var pressedID: UUID?

    /// Fixed geometry, so the popover's height is known before it is presented
    /// and never changes afterwards (5c).
    private enum Metrics {
        static let width: CGFloat = 300
        static let rowWithSnippet: CGFloat = 46
        static let rowPlain: CGFloat = 30
        static let groupHeader: CGFloat = 20
        static let itemSpacing: CGFloat = 2
        static let listInset: CGFloat = 8
        static let maxListHeight: CGFloat = 380
        static let emptyHeight: CGFloat = 56
        /// History rows are cheap, but not free — the filter trims anything past
        /// this and the list stays a plain VStack.
        static let renderCap = 40
    }

    var body: some View {
        VStack(spacing: 0) {
            filterRow
            Divider()
            if visible.isEmpty {
                Text(store.recent.isEmpty ? "No saved chats" : "No matches")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(height: Metrics.emptyHeight)
            } else {
                list
            }
        }
        .frame(width: Metrics.width)
        // Pop from the clock pill rather than materialize: origin top-right,
        // scale 0.92→1, y −6→0. Reduce Motion collapses it to opacity only.
        .scaleEffect(appeared || reduceMotion ? 1 : 0.92, anchor: .topTrailing)
        .offset(y: appeared || reduceMotion ? 0 : -6)
        .opacity(appeared ? 1 : 0)
        .animation(shellAnimation, value: appeared)
        // ⌘F inside the popover means "search the histories": the filter field is
        // already focused on open, so this re-focuses and selects it.
        .keyCommand("f") { filterFocusBump += 1 }
        .onAppear {
            selectedID = visible.first?.id
            appeared = true
        }
        .onChange(of: filter) { _, _ in selectedID = visible.first?.id }
    }

    // The filter row lands with the shell — only the list rows cascade.
    private var filterRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            KeyRoutingTextField(
                text: $filter,
                placeholder: "Filter chats…",
                focusBump: filterFocusBump,
                onMoveUp: { moveSelection(-1) },
                onMoveDown: { moveSelection(1) },
                onReturn: { _ in openSelected() },
                onEscape: {
                    close()
                    return true
                }
            )
            .frame(height: 16)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Plain VStack with fixed item heights: a LazyVStack re-estimates
                // as rows realize, which is exactly what made the popover resize
                // mid-pop (5c).
                VStack(alignment: .leading, spacing: Metrics.itemSpacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        itemView(item)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared || reduceMotion ? 0 : 4)
                            .animation(cascade(index), value: appeared)
                    }
                }
                .padding(Metrics.listInset)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: listHeight)
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func itemView(_ item: ListItem) -> some View {
        switch item {
        case let .header(title, _):
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.4))
                .textCase(.uppercase)
                .padding(.horizontal, 8)
                .frame(height: Metrics.groupHeader, alignment: .bottomLeading)
        case let .chat(meta):
            row(meta)
        }
    }

    // MARK: - Motion

    private var shellAnimation: Animation {
        if reduceMotion { return .easeOut(duration: 0.15) }
        return isClosing ? .easeIn(duration: 0.13) : .spring(response: 0.24, dampingFraction: 0.85)
    }

    /// 18ms stagger capped at the first 8 rows, so a long list never feels slow —
    /// everything past row 8 arrives with it. No stagger on the way out.
    private func cascade(_ index: Int) -> Animation {
        if reduceMotion || isClosing { return .easeOut(duration: 0.13) }
        return .easeOut(duration: 0.16).delay(Double(min(index, 8)) * 0.018)
    }

    /// Runs the designed out-animation, then dismisses, then hands over. The
    /// ordering is the point (5d): the popover is gone before the panel grows,
    /// because two springs at once is what made this read as jumpy.
    private func close(afterFlash: Bool = false, then action: (() -> Void)? = nil) {
        guard !isClosing else { return }
        let run = {
            isClosing = true
            appeared = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                dismiss()
                action?()
            }
        }
        if afterFlash {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: run)
        } else {
            run()
        }
    }

    private func open(_ meta: ConversationMeta) {
        guard !isClosing else { return }
        pressedID = meta.id
        close(afterFlash: true) { store.loadConversation(meta.id) }
    }

    // MARK: - Keyboard selection

    private func moveSelection(_ delta: Int) -> Bool {
        let items = visible
        guard !items.isEmpty else { return true }
        let current = items.firstIndex { $0.id == selectedID } ?? -1
        selectedID = items[min(max(current + delta, 0), items.count - 1)].id
        return true
    }

    private func openSelected() -> Bool {
        guard let meta = visible.first(where: { $0.id == selectedID }) ?? visible.first else { return true }
        open(meta)
        return true
    }

    private func row(_ meta: ConversationMeta) -> some View {
        let isCurrent = meta.id == store.conversationID
        let isHovered = hoveredID == meta.id
        let isSelected = selectedID == meta.id
        let isPressed = pressedID == meta.id
        // Only one row may carry the ⌘⌫ equivalent at a time: hover wins while
        // the mouse is over the list, keyboard selection owns it otherwise.
        let ownsDelete = isHovered || (isSelected && hoveredID == nil)
        return Button {
            open(meta)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if meta.isFork {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .help("Forked conversation")
                    }
                    Text(meta.title)
                        .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if ownsDelete {
                        Button {
                            store.deleteConversation(meta.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                                .contentShape(Circle())
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
            .padding(.horizontal, 8)
            // Fixed height, not padding: the popover's total height is computed
            // from these before it is presented (5c).
            .frame(height: rowHeight(meta), alignment: .leading)
            .background(
                isPressed ? Theme.color(accentHex).opacity(0.34)
                    : isCurrent ? Theme.color(accentHex).opacity(0.16)
                    : isHovered || isSelected ? Color.primary.opacity(0.06)
                    : .clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            // Keyboard selection reads as a ring so it stays distinguishable
            // from "this is the open chat" (accent fill) and hover.
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Theme.color(accentHex).opacity(0.7), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(meta.id)
        .onHover { inside in
            if inside {
                hoveredID = meta.id
            } else if hoveredID == meta.id {
                hoveredID = nil
            }
        }
    }

    // MARK: - Grouping & geometry

    private var filtered: [ConversationMeta] {
        guard !filter.isEmpty else { return store.recent }
        return store.recent.filter {
            $0.title.localizedCaseInsensitiveContains(filter)
                || $0.snippet.localizedCaseInsensitiveContains(filter)
        }
    }

    /// What actually renders — the render cap applies here so keyboard selection
    /// can never land on a row that isn't on screen.
    private var visible: [ConversationMeta] {
        Array(filtered.prefix(Metrics.renderCap))
    }

    /// Day headers and rows flattened into one list, so the height math is a sum.
    private enum ListItem {
        case header(String, key: String)
        case chat(ConversationMeta)

        var id: String {
            switch self {
            case let .header(_, key): "h:\(key)"
            case let .chat(meta): "c:\(meta.id.uuidString)"
            }
        }
    }

    private var items: [ListItem] {
        let calendar = Calendar.current
        var result: [ListItem] = []
        var lastKey: String?
        for meta in visible {
            let day = calendar.startOfDay(for: meta.updatedAt)
            let key = day.formatted(.iso8601.year().month().day())
            if key != lastKey {
                result.append(.header(groupTitle(for: meta.updatedAt, calendar: calendar), key: key))
                lastKey = key
            }
            result.append(.chat(meta))
        }
        return result
    }

    private func rowHeight(_ meta: ConversationMeta) -> CGFloat {
        meta.snippet.isEmpty ? Metrics.rowPlain : Metrics.rowWithSnippet
    }

    /// The list's presented height: the exact content height, capped. Known
    /// before the first layout pass, so the popover never resizes after it pops.
    private var listHeight: CGFloat {
        let items = items
        guard !items.isEmpty else { return 0 }
        let content = items.reduce(0) { total, item in
            switch item {
            case .header: total + Metrics.groupHeader
            case let .chat(meta): total + rowHeight(meta)
            }
        }
        let spacing = Metrics.itemSpacing * CGFloat(items.count - 1)
        return min(content + spacing + Metrics.listInset * 2, Metrics.maxListHeight)
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
