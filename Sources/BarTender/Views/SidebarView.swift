import SwiftUI

/// Notion-style sidebar: quiet rows, live values right-aligned, hover-revealed actions.
struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: AppletStore
    @EnvironmentObject private var runtime: AppletRuntimeEngine
    @Environment(\.openSettings) private var openSettings

    @State private var searchText = ""
    @State private var toolsLabelHovering = false
    @FocusState private var searchFocused: Bool

    private var filteredApplets: [AppletManifest] {
        guard !searchText.isEmpty else { return store.applets }
        return store.applets.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            workspaceMenu
            searchRow
                .padding(.top, 2)

            HStack {
                Text("Tools")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    model.beginNewTool()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(toolsLabelHovering ? 1 : 0)
                .disabled(model.generation?.phase.isActive == true)
                .help("New Tool (⌘N)")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
            .onHover { toolsLabelHovering = $0 }
            .animation(.snappy(duration: 0.12), value: toolsLabelHovering)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if filteredApplets.isEmpty {
                        Text(searchText.isEmpty ? "No tools yet — describe one below." : "No matching tools.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
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
                .padding(.horizontal, 6)
            }

            Divider()
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 1) {
                SidebarActionRow(
                    title: "New Tool",
                    systemImage: "plus",
                    shortcutHint: "⌘N",
                    action: { model.beginNewTool() }
                )
                .disabled(model.generation?.phase.isActive == true)

                SidebarActionRow(
                    title: "Settings",
                    systemImage: "gearshape",
                    shortcutHint: "⌘,",
                    action: { openSettings() }
                )
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .padding(.top, 6)
        .frame(minWidth: 200)
        .background {
            // Hidden shortcut: ⌘K focuses the filter field.
            Button("") { searchFocused = true }
                .keyboardShortcut("k", modifiers: [.command])
                .hidden()
        }
        .navigationTitle("Bar Tender")
    }

    // MARK: - Workspace menu

    private var workspaceMenu: some View {
        Menu {
            Button("Settings…") { openSettings() }
            Button("Recheck Providers") {
                Task { await model.refreshProviders() }
            }
        } label: {
            Text("Bar Tender")
                .font(.system(size: 13.5, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    // MARK: - Search

    private var searchRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onExitCommand {
                    searchText = ""
                    searchFocused = false
                }
            if searchText.isEmpty && !searchFocused {
                Text("⌘K")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
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

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: applet.iconSystemName)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
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
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .foregroundStyle(.primary)
            .background(
                selected
                    ? Color.primary.opacity(0.075)
                    : Color.primary.opacity(hovering ? 0.045 : 0),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(applet.enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.12), value: hovering)
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

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
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
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .foregroundStyle(.primary)
            .background(
                Color.primary.opacity(hovering ? 0.045 : 0),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.12), value: hovering)
    }
}

