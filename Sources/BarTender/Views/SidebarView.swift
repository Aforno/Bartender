import SwiftUI

/// Notion-style sidebar: quiet rows, live values right-aligned, hover-revealed actions.
struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: AppletStore
    @EnvironmentObject private var runtime: AppletRuntimeEngine

    @State private var searchText = ""
    @State private var searchVisible = false
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var filteredApplets: [AppletManifest] {
        guard !searchText.isEmpty else { return store.applets }
        return store.applets.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
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
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, PremiumStyle.sidebarInset + PremiumStyle.rowInsetH)
                .padding(.top, PremiumStyle.space12)
                .padding(.bottom, PremiumStyle.space4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if filteredApplets.isEmpty {
                        Text(searchText.isEmpty ? "No tools yet — describe one below." : "No matching tools.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
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
                                onDelete: {
                                    model.selection = applet.id
                                    model.deleteSelected()
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, PremiumStyle.sidebarInset)
            }

            Divider()
                .padding(.horizontal, PremiumStyle.sidebarInset)
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
        .background {
            // Hidden shortcut: ⌘K toggles the filter field.
            Button("") { toggleSearch() }
                .keyboardShortcut("k", modifiers: [.command])
                .hidden()
        }
        .navigationTitle("Bar Tender")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Bar Tender")
                .font(.system(size: 14, weight: .semibold, design: .serif))

            Spacer(minLength: 0)

            Button {
                toggleSearch()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Search (⌘K)")
            .accessibilityLabel("Search tools")
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
                .foregroundStyle(.tertiary)
                .frame(width: 18)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onExitCommand {
                    toggleSearch()
                }
                .accessibilityIdentifier("tool-search")
            if searchText.isEmpty && !searchFocused {
                Text("⌘K")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, PremiumStyle.rowInsetH)
        .padding(.vertical, PremiumStyle.rowInsetV)
        .padding(.horizontal, PremiumStyle.sidebarInset)
    }

    // MARK: - Row value

    private func value(for applet: AppletManifest) -> String {
        if !applet.enabled { return "off" }
        if applet.kind == .generatedTool && !model.isExecutionApproved(applet) {
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
    let onDelete: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: applet.iconSystemName)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 12.5))
                    .foregroundStyle(selected ? PremiumStyle.brand : Color.secondary)
                    .frame(width: 18)

                Text(applet.name)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Spacer(minLength: 6)

                if hovering {
                    Menu {
                        Button(applet.enabled ? "Disable" : "Enable", action: onToggleEnabled)
                        Button("Delete", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 16)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 20)
                } else {
                    Text(value)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, PremiumStyle.rowInsetH)
            .padding(.vertical, PremiumStyle.rowInsetV)
            .foregroundStyle(.primary)
            .background(
                selected
                    ? PremiumStyle.selectionFill
                    : Color.primary.opacity(hovering ? 0.045 : 0),
                in: RoundedRectangle(cornerRadius: PremiumStyle.chipRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: PremiumStyle.chipRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(applet.name)
        .accessibilityValue(value)
        .accessibilityIdentifier("tool-row.\(applet.id.uuidString)")
        .opacity(applet.enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: hovering)
        .contextMenu {
            Button(applet.enabled ? "Disable" : "Enable", action: onToggleEnabled)
            Button("Delete", role: .destructive, action: onDelete)
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
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 13))
            Spacer()
            if let shortcutHint {
                Text(shortcutHint)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, PremiumStyle.rowInsetH)
        .padding(.vertical, PremiumStyle.rowInsetV)
        .foregroundStyle(.primary)
        .background(
            Color.primary.opacity(hovering ? 0.045 : 0),
            in: RoundedRectangle(cornerRadius: PremiumStyle.chipRadius, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: PremiumStyle.chipRadius, style: .continuous))
    }
}
