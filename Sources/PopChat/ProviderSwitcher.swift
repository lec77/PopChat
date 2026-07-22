import AppKit
import SwiftUI

/// The header pill's provider + model + effort switcher (delta 5, 7c) — replaces the stock
/// `Menu`, which forced provider and model to be chosen in two separate,
/// order-dependent steps.
///
/// The rail PREVIEWS and a click COMMITS: arrowing or hovering over a provider
/// shows its models on the right without switching anything, so browsing what a
/// provider offers can't redirect the live conversation. Clicking a model commits
/// provider + model together (`ProviderStore.select`); clicking a provider row
/// commits it with its remembered model.
///
/// Like the history popover (delta 3, 5c) it opens at its FINAL size: every row
/// has a fixed height and the body height is computed before presentation, so
/// NSPopover never re-sizes mid-pop against a 120pt empty panel.
struct ProviderSwitcher: View {
    @ObservedObject var store: ProviderStore
    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Which provider's models the right column is showing. Not a selection —
    /// nothing is switched until a row is clicked.
    @State private var previewID = UUID()
    @State private var column = Column.providers
    @State private var modelIndex = 0
    @State private var effortIndex = 0
    @State private var hoveredRow: String?
    @State private var appeared = false
    @State private var isClosing = false

    init(store: ProviderStore) {
        self.store = store
        let providerID = store.selectedID
        let availableModels = Array((store.knownModels[providerID] ?? []).prefix(Metrics.renderCap))
        let rememberedModel = store.rememberedModel(providerID)
        let initialModelIndex = availableModels.firstIndex(of: rememberedModel) ?? 0
        let initialModel = availableModels.indices.contains(initialModelIndex)
            ? availableModels[initialModelIndex]
            : rememberedModel
        let availableEfforts = store.supportedEfforts(providerID, model: initialModel)
        let rememberedEffort = store.rememberedEffort(providerID, model: initialModel)

        _previewID = State(initialValue: providerID)
        _modelIndex = State(initialValue: initialModelIndex)
        _effortIndex = State(initialValue: rememberedEffort.flatMap {
            availableEfforts.firstIndex(of: $0)
        } ?? 0)
    }

    private enum Column { case providers, models, efforts }

    private enum Metrics {
        static let width: CGFloat = 372
        static let effortWidth: CGFloat = 118
        static let railWidth: CGFloat = 150
        static let row: CGFloat = 25
        static let header: CGFloat = 21
        static let inset: CGFloat = 6
        static let maxBody: CGFloat = 320
        /// Long catalogs (OpenRouter ships 300+) scroll rather than grow.
        static let renderCap = 200
    }

    private var accent: Color { Theme.color(accentHex) }
    private var rail: [Provider] { store.configuredProviders }
    private var previewProvider: Provider? { store.providers.first { $0.id == previewID } }
    private var models: [String] {
        Array((store.knownModels[previewID] ?? []).prefix(Metrics.renderCap))
    }
    private var previewModel: String {
        models.indices.contains(modelIndex) ? models[modelIndex] : store.rememberedModel(previewID)
    }
    private var efforts: [String] {
        store.supportedEfforts(previewID, model: previewModel)
    }
    /// Reserve the third lane whenever any provider in this popover can use it,
    /// keeping the shell width stable while the user previews providers/models.
    private var switcherWidth: CGFloat {
        rail.contains(where: { store.hasEffortModels($0.id) })
            ? Metrics.width + Metrics.effortWidth
            : Metrics.width
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                providerRail
                Divider()
                modelColumn
                if !efforts.isEmpty {
                    Divider()
                    effortColumn
                }
            }
            .frame(height: bodyHeight)
            Divider()
            footer
        }
        .frame(width: switcherWidth)
        .background { keyCapture }
        // Pops from the pill's left edge (5b's curve, 7c's timing).
        .scaleEffect(appeared || reduceMotion ? 1 : 0.96, anchor: .topLeading)
        .opacity(appeared ? 1 : 0)
        .animation(shellAnimation, value: appeared)
        .onAppear {
            // Re-assert the live provider every presentation. `init`'s
            // State(initialValue:) seeds only the FIRST construction of this view
            // identity — it's there so bodyHeight/switcherWidth are final before
            // the popover presents (5c) — so a re-presented popover that kept its
            // state would otherwise open on whatever was last previewed, and ↩
            // would commit a provider the user never browsed to in this session.
            previewID = store.selectedID
            syncModelIndex()
            syncEffortIndex()
            store.lazyFetchModels(for: store.selectedID)
            appeared = true
        }
        .onChange(of: previewID) { _, id in
            store.lazyFetchModels(for: id)
            syncModelIndex()
            syncEffortIndex()
        }
        .onChange(of: models) { _, _ in
            syncModelIndex()
            syncEffortIndex()
        }
        .onChange(of: modelIndex) { _, _ in
            syncEffortIndex()
        }
    }

    // MARK: - Rail

    private var providerRail: some View {
        VStack(alignment: .leading, spacing: 1) {
            columnHeader("Providers")
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(rail) { provider in
                        railRow(provider)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            addProviderRow
        }
        .padding(Metrics.inset)
        .frame(width: Metrics.railWidth, alignment: .leading)
    }

    private func railRow(_ provider: Provider) -> some View {
        let isLive = provider.id == store.selectedID
        let isPreviewed = provider.id == previewID
        return Button {
            commitProvider(provider.id)
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(store.isConfigured(provider) ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(provider.name)
                    .font(.system(size: 12, weight: isLive ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isLive ? Color.primary : Color.primary.opacity(0.8))
            .padding(.horizontal, 8)
            .frame(height: Metrics.row, alignment: .leading)
            .background(
                isLive ? Color.primary.opacity(0.12)
                    : isPreviewed || hoveredRow == "p:\(provider.id)" ? Color.primary.opacity(0.06)
                    : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hoveredRow = inside ? "p:\(provider.id)" : (hoveredRow == "p:\(provider.id)" ? nil : hoveredRow)
            // Hover previews, exactly like arrowing does.
            if inside {
                previewID = provider.id
                column = .providers
            }
        }
    }

    private var addProviderRow: some View {
        dimRow(icon: "plus", title: "Add provider…", key: "add") {
            close { NotificationCenter.default.post(name: .popChatOpenSettings, object: nil) }
        }
    }

    // MARK: - Models

    private var modelColumn: some View {
        VStack(alignment: .leading, spacing: 1) {
            columnHeader(modelHeaderTitle)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if store.isFetching(previewID) {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                            Text("Fetching models…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: Metrics.row, alignment: .leading)
                    }
                    ForEach(Array(models.enumerated()), id: \.element) { index, model in
                        modelRow(model, index: index)
                    }
                    // Fetch failures surface HERE, next to the provider they
                    // belong to — never only as a label buried in Settings.
                    if let error = store.modelFetchErrors[previewID] {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    } else if models.isEmpty, !store.isFetching(previewID) {
                        Text("No models fetched yet")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .frame(height: Metrics.row, alignment: .leading)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            dimRow(icon: "arrow.clockwise", title: "Refresh list", key: "refresh") {
                Task { await store.fetchModels(for: previewID) }
            }
        }
        .padding(Metrics.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modelRow(_ model: String, index: Int) -> some View {
        let isCurrent = model == store.rememberedModel(previewID)
        let isFocused = column == .models && index == modelIndex
        return Button {
            commitModel(model)
        } label: {
            HStack(spacing: 8) {
                Text(model)
                    .font(.system(size: 12, weight: isCurrent ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
            .foregroundStyle(isCurrent ? Color.primary : Color.primary.opacity(0.8))
            .padding(.horizontal, 8)
            .frame(height: Metrics.row, alignment: .leading)
            .background(
                isCurrent ? Color.primary.opacity(0.08)
                    : isFocused || hoveredRow == "m:\(model)" ? Color.primary.opacity(0.06)
                    : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(accent.opacity(0.7), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hoveredRow = inside ? "m:\(model)" : (hoveredRow == "m:\(model)" ? nil : hoveredRow)
            // Cascading-menu behaviour: moving across a model previews its
            // supported effort choices without committing either value.
            if inside {
                modelIndex = index
                column = .models
            }
        }
    }

    private var modelHeaderTitle: String {
        let name = previewProvider?.name ?? "Models"
        let count = store.knownModels[previewID]?.count ?? 0
        return count > 0 ? "\(name) · \(count) models" : name
    }

    // MARK: - Reasoning effort

    private var effortColumn: some View {
        VStack(alignment: .leading, spacing: 1) {
            columnHeader("Effort")
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(efforts.enumerated()), id: \.element) { index, effort in
                        effortRow(effort, index: index)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            Text("For \(previewModel)")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .frame(height: Metrics.row, alignment: .leading)
        }
        .padding(Metrics.inset)
        .frame(width: Metrics.effortWidth, alignment: .leading)
    }

    private func effortRow(_ effort: String, index: Int) -> some View {
        let isCurrent = effort == store.rememberedEffort(previewID, model: previewModel)
        let isFocused = column == .efforts && index == effortIndex
        return Button {
            commitEffort(effort)
        } label: {
            HStack(spacing: 6) {
                Text(effortLabel(effort))
                    .font(.system(size: 12, weight: isCurrent ? .medium : .regular))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
            .foregroundStyle(isCurrent ? Color.primary : Color.primary.opacity(0.8))
            .padding(.horizontal, 8)
            .frame(height: Metrics.row, alignment: .leading)
            .background(
                isCurrent ? Color.primary.opacity(0.08)
                    : isFocused || hoveredRow == "e:\(effort)" ? Color.primary.opacity(0.06)
                    : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(accent.opacity(0.7), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hoveredRow = inside ? "e:\(effort)" : (hoveredRow == "e:\(effort)" ? nil : hoveredRow)
            if inside {
                effortIndex = index
                column = .efforts
            }
        }
    }

    private func effortLabel(_ effort: String) -> String {
        switch effort {
        case "xhigh": "Extra High"
        default: effort.capitalized
        }
    }

    // MARK: - Chrome

    private func columnHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.primary.opacity(0.45))
            .padding(.horizontal, 8)
            .frame(height: Metrics.header, alignment: .bottomLeading)
    }

    private func dimRow(icon: String, title: String, key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary.opacity(hoveredRow == key ? 0.8 : 0.5))
            .padding(.horizontal, 8)
            .frame(height: Metrics.row, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hoveredRow = inside ? key : (hoveredRow == key ? nil : hoveredRow)
        }
    }

    private var footer: some View {
        Button {
            close { NotificationCenter.default.post(name: .popChatOpenSettings, object: nil) }
        } label: {
            HStack(spacing: 8) {
                Text("Manage providers…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                // Renders the hint only: the working ⌘, is the invisible app
                // menu's item (AppDelegate).
                Text("⌘,")
                    .font(.system(size: 10))
                    .foregroundStyle(.primary.opacity(0.6))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Geometry

    /// Known before presentation: the taller column's content, capped. Rows are
    /// fixed-height by construction, so this can't drift (5c).
    private var bodyHeight: CGFloat {
        let railContent = Metrics.header + CGFloat(rail.count + 1) * (Metrics.row + 1)
        let modelRows = max(models.count, 1) + 1 // + the refresh row
        let modelContent = Metrics.header + CGFloat(modelRows) * (Metrics.row + 1)
        let effortRows = efforts.isEmpty ? 0 : efforts.count + 1 // + model hint
        let effortContent = Metrics.header + CGFloat(effortRows) * (Metrics.row + 1)
        let tallest = max(max(railContent, modelContent), effortContent) + Metrics.inset * 2
        return min(max(tallest, 120), Metrics.maxBody)
    }

    private var shellAnimation: Animation {
        if reduceMotion { return .easeOut(duration: 0.15) }
        return isClosing ? .easeIn(duration: 0.13) : .easeOut(duration: 0.18)
    }

    // MARK: - Commit & close

    /// Passes only an EXPLICIT prior choice. `rememberedEffort` would hand back the
    /// model's advertised default, and `select` writes whatever it is given into
    /// `selectedModelEfforts` — so committing a model would silently freeze today's
    /// default in as the user's pick and ignore the provider's future one.
    private func commitModel(_ model: String) {
        store.select(previewID, model: model, effort: store.chosenEffort(previewID, model: model))
        close()
    }

    private func commitEffort(_ effort: String) {
        store.select(previewID, model: previewModel, effort: effort)
        close()
    }

    private func commitProvider(_ id: UUID) {
        let model = store.rememberedModel(id)
        store.select(id, model: model, effort: store.chosenEffort(id, model: model))
        close()
    }

    /// Runs the out-animation before dismissing, then hands over — same ordering
    /// discipline as the history popover (5d).
    private func close(then action: (() -> Void)? = nil) {
        guard !isClosing else { return }
        isClosing = true
        appeared = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
            dismiss()
            action?()
        }
    }

    // MARK: - Keyboard

    /// ↑↓ within a column, ←→ across, ↩ commits, esc closes. A popover is its own
    /// window, so the keys are captured there rather than by the panel.
    private var keyCapture: some View {
        KeyCaptureView(
            onKey: { key in
                switch key {
                case .up: move(-1)
                case .down: move(1)
                case .left:
                    switch column {
                    case .providers: break
                    case .models: column = .providers
                    case .efforts: column = .models
                    }
                case .right:
                    if column == .providers, !models.isEmpty {
                        column = .models
                        syncModelIndex()
                    } else if column == .models, !efforts.isEmpty {
                        column = .efforts
                        syncEffortIndex()
                    }
                case .return:
                    if column == .efforts, efforts.indices.contains(effortIndex) {
                        commitEffort(efforts[effortIndex])
                    } else if column == .models, models.indices.contains(modelIndex) {
                        commitModel(models[modelIndex])
                    } else {
                        commitProvider(previewID)
                    }
                case .escape:
                    close()
                }
                return true
            }
        )
        .frame(width: 1, height: 1)
        .opacity(0)
    }

    private func move(_ delta: Int) {
        switch column {
        case .providers:
            guard !rail.isEmpty else { return }
            let current = rail.firstIndex { $0.id == previewID } ?? 0
            previewID = rail[min(max(current + delta, 0), rail.count - 1)].id
        case .models:
            guard !models.isEmpty else { return }
            modelIndex = min(max(modelIndex + delta, 0), models.count - 1)
        case .efforts:
            guard !efforts.isEmpty else { return }
            effortIndex = min(max(effortIndex + delta, 0), efforts.count - 1)
        }
    }

    /// Points the model cursor at the previewed provider's remembered model, so
    /// ↩ right after ←→ commits what the checkmark is on.
    private func syncModelIndex() {
        let remembered = store.rememberedModel(previewID)
        modelIndex = models.firstIndex(of: remembered) ?? 0
    }

    private func syncEffortIndex() {
        let remembered = store.rememberedEffort(previewID, model: previewModel)
        effortIndex = remembered.flatMap { efforts.firstIndex(of: $0) } ?? 0
        if efforts.isEmpty, column == .efforts { column = .models }
    }
}

// MARK: - Key capture

/// Invisible first responder for arrow/return/escape inside the switcher popover.
///
/// Not `.onKeyPress`: that needs SwiftUI focus, which nothing in this popover
/// otherwise wants (there is no text field here, unlike the history popover's
/// filter). A plain NSView that accepts first responder is both smaller and
/// certain to see the arrows before any control does.
private struct KeyCaptureView: NSViewRepresentable {
    enum Key { case up, down, left, right, `return`, escape }

    var onKey: (Key) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = CaptureView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? CaptureView)?.onKey = onKey
    }

    private final class CaptureView: NSView {
        var onKey: ((Key) -> Bool)?
        private var claimed = false

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !claimed else { return }
            claimed = true
            // Never synchronously from inside AppKit's subtree walk (see
            // AutoFocusingTextField in SearchField.swift for the crash this avoids).
            RunLoop.main.perform(inModes: [.common]) { window.makeFirstResponder(self) }
        }

        override func keyDown(with event: NSEvent) {
            let key: Key?
            switch event.keyCode {
            case 126: key = .up
            case 125: key = .down
            case 123: key = .left
            case 124: key = .right
            case 36, 76: key = .return
            case 53: key = .escape
            default: key = nil
            }
            if let key, onKey?(key) == true { return }
            super.keyDown(with: event)
        }
    }
}
