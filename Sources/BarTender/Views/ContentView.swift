import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var providers: AIProviderService
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if providers.anyProviderReady || isStillChecking {
                mainWorkspace
            } else {
                SetupErrorView {
                    Task { await model.refreshProviders() }
                }
                .environmentObject(providers)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
    }

    private var isStillChecking: Bool {
        providers.statuses.values.contains {
            if case .checking = $0 { return true }
            return false
        }
    }

    private var mainWorkspace: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 280)
        } detail: {
            DetailView()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ComposerView()
                }
                .inspector(isPresented: $model.showInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
                }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.beginNewTool()
                } label: {
                    Label("New Tool", systemImage: "plus")
                }
                .help("Open a blank page to build a new menu bar tool (⌘N)")
                .disabled(model.generation?.phase.isActive == true)

                Toggle(isOn: $model.showInspector) {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .toggleStyle(.button)
                .help("Show or hide the inspector")

                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open settings")
            }
        }
        .overlay(alignment: .top) {
            if let banner = model.bannerMessage {
                BannerView(text: banner) {
                    model.bannerMessage = nil
                }
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.bannerMessage)
    }
}

private struct BannerView: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(PremiumStyle.cardStroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 12, y: 3)
        .padding(.horizontal, 20)
        .frame(maxWidth: 560)
    }
}
