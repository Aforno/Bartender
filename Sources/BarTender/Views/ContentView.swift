import SwiftUI

struct ContentView: View {
    private enum NavigationDestination: Equatable {
        case newTool
        case tool(UUID)

        init(selection: UUID?) {
            self = selection.map(Self.tool) ?? .newTool
        }

        var selection: UUID? {
            switch self {
            case .newTool: nil
            case .tool(let id): id
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var providers: AIProviderService
    @EnvironmentObject private var store: AppletStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var backHistory: [NavigationDestination] = []
    @State private var forwardHistory: [NavigationDestination] = []
    @State private var suppressNextHistoryUpdate = false

    var body: some View {
        mainWorkspace
        .frame(minWidth: 720, minHeight: 500)
        .background(WindowChromeConfigurator())
        .sheet(isPresented: $model.showingProviderSetup) {
            ProviderSetupSheet()
                .environmentObject(model)
                .environmentObject(providers)
        }
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) {
                    titlebarNavigationControls
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) {
                    titlebarNavigationControls
                }
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onChange(of: model.selection) { oldSelection, newSelection in
            guard oldSelection != newSelection else { return }
            if suppressNextHistoryUpdate {
                suppressNextHistoryUpdate = false
                return
            }
            if oldSelection == nil || store.applet(id: oldSelection) != nil {
                backHistory.append(NavigationDestination(selection: oldSelection))
            }
            forwardHistory.removeAll()
        }
        .onReceive(store.$applets) { applets in
            let ids = Set(applets.map(\.id))
            backHistory.removeAll { destination in
                if case .tool(let id) = destination { return !ids.contains(id) }
                return false
            }
            forwardHistory.removeAll { destination in
                if case .tool(let id) = destination { return !ids.contains(id) }
                return false
            }
            if let selection = model.selection, !ids.contains(selection) {
                model.selection = applets.first?.id
            }
        }
    }

    private var isStillChecking: Bool {
        providers.statuses.values.contains {
            if case .checking = $0 { return true }
            return false
        }
    }

    private var titlebarNavigationControls: some View {
        HStack(spacing: 8) {
            Button(action: navigateBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(backHistory.isEmpty)
            .help("Back")
            .accessibilityLabel("Back")
            .accessibilityIdentifier("navigate-back")

            Button(action: navigateForward) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(forwardHistory.isEmpty)
            .help("Forward")
            .accessibilityLabel("Forward")
            .accessibilityIdentifier("navigate-forward")
        }
        .font(.system(size: 15, weight: .medium))
        .frame(height: 28)
    }

    private var mainWorkspace: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 280)
                .background(PremiumStyle.sidebarBackground)
        } detail: {
            VStack(spacing: 0) {
                DetailView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ComposerView()
                    .background(PremiumStyle.canvas)
            }
            .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
            .background {
                PremiumStyle.canvas
                    .ignoresSafeArea(edges: .top)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .overlay(alignment: .top) {
            VStack(spacing: PremiumStyle.space8) {
                if !providers.anyProviderReady, !isStillChecking {
                    ProviderUnavailableBanner {
                        model.showingProviderSetup = true
                    }
                }

                if let banner = model.bannerMessage {
                    BannerView(text: banner) {
                        model.bannerMessage = nil
                    }
                }
            }
            .padding(.top, PremiumStyle.space8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        .animation(reduceMotion ? nil : .snappy, value: model.bannerMessage)
    }

    private func navigateBack() {
        guard let destination = backHistory.popLast() else { return }
        forwardHistory.append(NavigationDestination(selection: model.selection))
        navigate(to: destination)
    }

    private func navigateForward() {
        guard let destination = forwardHistory.popLast() else { return }
        backHistory.append(NavigationDestination(selection: model.selection))
        navigate(to: destination)
    }

    private func navigate(to destination: NavigationDestination) {
        if case .tool(let id) = destination, store.applet(id: id) == nil {
            return
        }
        suppressNextHistoryUpdate = true
        model.selection = destination.selection
    }
}
