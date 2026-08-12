import SwiftUI

/// Compact AgentNotch-style library: deep black, quiet rows, and state-first values.
struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: AppletStore
    @EnvironmentObject private var runtime: AppletRuntimeEngine

    @State private var searchText = ""
    @State private var searchVisible = false
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var filteredApplets: [AppletManifest] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.applets }
        return store.applets.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if searchVisible {
                searchRow
                    .padding(.top, PremiumStyle.space2)
                    .transition(.opacity)
            }

            SidebarActionRow(
                title: "New Tool",
                systemImage: "plus",
                shortcutHint: "⌘N",
                action: { model.beginNewTool() }
            )
            .disabled(model.generation?.phase.isActive == true)
            .accessibilityIdentifier("new-tool")
            .padding(.horizontal, PremiumStyle.sidebarInset)
            .padding(.top, PremiumStyle.space4)

            Text("Tools")
                .font(BarTenderFont.sectionLabel)
                .foregroundStyle(Color.white.opacity(0.74))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, PremiumStyle.sidebarInset + PremiumStyle.rowInsetH)
                .padding(.top, PremiumStyle.space12)
                .padding(.bottom, PremiumStyle.space4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if filteredApplets.isEmpty {
                        Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "No tools yet — describe one below."
                            : "No matching tools.")
                            .font(BarTenderFont.caption)
                            .foregroundStyle(PremiumStyle.tertiaryText)
                            .padding(.horizontal, PremiumStyle.rowInsetH)
                            .padding(.vertical, PremiumStyle.rowInsetV)
                    } else {
                        ForEach(filteredApplets) { applet in
                            ToolRow(
                                applet: applet,
                                value: value(for: applet),
                                selected: model.selection == applet.id,
                                onSelect: { model.selection = applet.id },
                                onToggleEnabled: { model.toggleEnabled(applet) },
                                deletionDisabled: model.generation?.phase.isActive == true,
                                onDelete: { model.deleteApplet(id: applet.id) }
                            )
                        }
                    }
                }
                .padding(.horizontal, PremiumStyle.sidebarInset)
            }

            BarTenderHairline()
                .padding(.top, PremiumStyle.space4)

            SidebarSettingsRow(
                title: "Settings",
                systemImage: "gearshape",
                shortcutHint: "⌘,"
            )
            .padding(.horizontal, PremiumStyle.sidebarInset)
            .padding(.top, PremiumStyle.space4)
            .padding(.bottom, PremiumStyle.sidebarInset)
        }
        .padding(.top, PremiumStyle.sidebarInset)
        .frame(minWidth: 200)
        .navigationTitle("Bar Tender")
        .foregroundStyle(PremiumStyle.primaryText)
        .deepBlackWindowSurface()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Bar Tender")
                .font(BarTenderFont.title)
                .foregroundStyle(PremiumStyle.primaryText)

            Spacer(minLength: 0)

            Button {
                toggleSearch()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .contentShape(Rectangle())
            }
            .buttonStyle(BarTenderIconButtonStyle())
            .keyboardShortcut("k", modifiers: [.command])
            .help("Search (⌘K)")
            .accessibilityLabel("Search tools")
            .accessibilityIdentifier("toggle-tool-search")
        }
        .padding(.horizontal, PremiumStyle.sidebarInset + PremiumStyle.rowInsetH)
        .padding(.vertical, PremiumStyle.space4)
    }

    private func toggleSearch() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.15)) {
            if searchVisible {
                searchText = ""
                searchVisible = false
                searchFocused = false
            } else {
                searchVisible = true
                searchFocused = true
            }
        }
    }

    // MARK: - Search

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5))
                .foregroundStyle(PremiumStyle.tertiaryText)
                .frame(width: 18)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(BarTenderFont.body)
                .foregroundStyle(PremiumStyle.primaryText)
                .focused($searchFocused)
                .onExitCommand {
                    toggleSearch()
                }
                .accessibilityIdentifier("tool-search")
            if searchText.isEmpty && !searchFocused {
                Text("⌘K")
                    .font(BarTenderFont.caption)
                    .foregroundStyle(PremiumStyle.tertiaryText)
            }
        }
        .padding(.horizontal, PremiumStyle.rowInsetH)
        .padding(.vertical, PremiumStyle.rowInsetV)
        .background(
            PremiumStyle.raised,
            in: RoundedRectangle(cornerRadius: PremiumStyle.controlRadius, style: .continuous)
        )
        .padding(.horizontal, PremiumStyle.sidebarInset)
    }

    // MARK: - Row value

    private func value(for applet: AppletManifest) -> String {
        if !applet.enabled { return "off" }
        if model.isValidatingExecution(applet) { return "testing" }
        if (applet.kind == .generatedTool || applet.kind == .shellCommand)
            && !model.isExecutionApproved(applet) {
            return "waiting"
        }
        if let snap = runtime.snapshots[applet.id] {
            return snap.isHealthy
                ? TitleRenderer.shortMenuTitle(snap.title)
                : TitleRenderer.shortMenuTitle(snap.statusText)
        }
        return applet.kind.displayName
    }
}

// MARK: - Tool row

/// A single library row: icon, name, live value; hover reveals a ••• menu.
private struct ToolRow: View {
    let applet: AppletManifest
    let value: String
    let selected: Bool
    let onSelect: () -> Void
    let onToggleEnabled: () -> Void
    let deletionDisabled: Bool
    let onDelete: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Image(systemName: applet.iconSystemName)
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? PremiumStyle.primaryText : PremiumStyle.secondaryText)
                        .frame(width: 18)

                    Text(applet.name)
                        .font(BarTenderFont.bodyEmphasis)
                        .lineLimit(1)
                        .layoutPriority(1)

                    Spacer(minLength: 6)

                    Text(value)
                        .font(BarTenderFont.caption)
                        .foregroundStyle(PremiumStyle.secondaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 76, alignment: .trailing)
                }
                .padding(.leading, PremiumStyle.rowInsetH)
                .padding(.vertical, PremiumStyle.rowInsetV)
                .foregroundStyle(PremiumStyle.primaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(applet.name)
            .accessibilityValue(value)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("tool-row.\(applet.id.uuidString)")

            Menu {
                Button(applet.enabled ? "Disable" : "Enable", action: onToggleEnabled)
                Button("Delete", role: .destructive, action: onDelete)
                    .disabled(deletionDisabled)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PremiumStyle.secondaryText.opacity(hovering || selected ? 1 : 0.55))
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Actions for \(applet.name)")
            .accessibilityLabel("Actions for \(applet.name)")
            .padding(.trailing, 2)
        }
        .background(
            selected
                ? PremiumStyle.selectionFill
                : Color.white.opacity(hovering ? 0.055 : 0),
            in: RoundedRectangle(cornerRadius: PremiumStyle.chipRadius, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: PremiumStyle.chipRadius, style: .continuous))
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: hovering)
        .contextMenu {
            Button(applet.enabled ? "Disable" : "Enable", action: onToggleEnabled)
            Button("Delete", role: .destructive, action: onDelete)
                .disabled(deletionDisabled)
        }
    }
}

// MARK: - Footer action row

private struct SidebarActionRow: View {
    let title: String
    let systemImage: String
    var shortcutHint: String? = nil
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            SidebarRowLabel(
                title: title,
                systemImage: systemImage,
                shortcutHint: shortcutHint,
                hovering: hovering
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: hovering)
    }
}

private struct SidebarSettingsRow: View {
    let title: String
    let systemImage: String
    var shortcutHint: String? = nil

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsLink {
            SidebarRowLabel(
                title: title,
                systemImage: systemImage,
                shortcutHint: shortcutHint,
                hovering: hovering
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: hovering)
    }
}

private struct SidebarRowLabel: View {
    let title: String
    let systemImage: String
    let shortcutHint: String?
    let hovering: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(PremiumStyle.secondaryText)
                .frame(width: 18)
            Text(title)
                .font(BarTenderFont.bodyEmphasis)
            Spacer()
            if let shortcutHint {
                Text(shortcutHint)
                    .font(BarTenderFont.caption)
                    .foregroundStyle(PremiumStyle.tertiaryText)
            }
        }
        .padding(.horizontal, PremiumStyle.rowInsetH)
        .padding(.vertical, PremiumStyle.rowInsetV)
        .foregroundStyle(PremiumStyle.primaryText)
        .background(
            Color.white.opacity(hovering ? 0.055 : 0),
            in: RoundedRectangle(cornerRadius: PremiumStyle.chipRadius, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: PremiumStyle.chipRadius, style: .continuous))
    }
}
