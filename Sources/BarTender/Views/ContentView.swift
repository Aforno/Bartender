import AppKit
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
    @State private var sidebarVisible = true
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
        .toolbarBackground(.hidden, for: .windowToolbar)
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
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                    sidebarVisible.toggle()
                }
            } label: {
                ToolbarSVGIcon(name: "sidebar-toggle", fallbackSystemImage: "sidebar.left")
            }
            .buttonStyle(.plain)
            .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
            .accessibilityLabel(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
            .accessibilityIdentifier("toggle-sidebar")

            Button(action: navigateBack) {
                ToolbarSVGIcon(name: "back", fallbackSystemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(backHistory.isEmpty)
            .help("Back")
            .accessibilityLabel("Back")
            .accessibilityIdentifier("navigate-back")

            Button(action: navigateForward) {
                ToolbarSVGIcon(name: "forward", fallbackSystemImage: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(forwardHistory.isEmpty)
            .help("Forward")
            .accessibilityLabel("Forward")
            .accessibilityIdentifier("navigate-forward")
        }
    }

    private var mainWorkspace: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 224)
                .background {
                    Rectangle()
                        .fill(PremiumStyle.sidebarBackground)
                        .ignoresSafeArea(edges: .top)
                }
                .frame(width: sidebarVisible ? 224 : 0, alignment: .leading)
                .clipped()
                .opacity(sidebarVisible ? 1 : 0)
                .allowsHitTesting(sidebarVisible)
                .accessibilityHidden(!sidebarVisible)

            Divider()
                .frame(width: sidebarVisible ? 1 : 0)
                .opacity(sidebarVisible ? 1 : 0)

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
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: sidebarVisible)
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

/// Keep the title-bar surface transparent and suppress window shadows when the
/// window is zoomed edge-to-edge or occupying its fullscreen Space.
private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        attachWindow(for: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        attachWindow(for: view, coordinator: context.coordinator)
    }

    private func attachWindow(for view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async {
            coordinator.attach(to: view.window)
        }
    }

    final class Coordinator: NSObject {
        private weak var window: NSWindow?

        func attach(to window: NSWindow?) {
            guard self.window !== window else {
                updateWindowShadow()
                return
            }

            NotificationCenter.default.removeObserver(self)
            self.window = window

            guard let window else { return }
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(windowFrameChanged), name: NSWindow.didMoveNotification, object: window)
            center.addObserver(self, selector: #selector(windowFrameChanged), name: NSWindow.didResizeNotification, object: window)
            center.addObserver(self, selector: #selector(windowFrameChanged), name: NSWindow.didChangeScreenNotification, object: window)
            center.addObserver(self, selector: #selector(windowWillEnterFullScreen), name: NSWindow.willEnterFullScreenNotification, object: window)
            center.addObserver(self, selector: #selector(windowFrameChanged), name: NSWindow.didEnterFullScreenNotification, object: window)
            center.addObserver(self, selector: #selector(windowFrameChanged), name: NSWindow.didExitFullScreenNotification, object: window)
            configureWindowAppearance(window)
            updateWindowShadow()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func windowFrameChanged(_ notification: Notification) {
            updateWindowShadow()
        }

        @objc private func windowWillEnterFullScreen(_ notification: Notification) {
            window?.hasShadow = false
        }

        private func configureWindowAppearance(_ window: NSWindow) {
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
        }

        private func updateWindowShadow() {
            guard let window else { return }
            let touchesVisibleScreenEdges = window.screen.map {
                fillsVisibleScreen(window.frame, visibleFrame: $0.visibleFrame)
            } ?? false
            window.hasShadow = !(window.styleMask.contains(.fullScreen) || touchesVisibleScreenEdges)
        }

        private func fillsVisibleScreen(_ frame: NSRect, visibleFrame: NSRect) -> Bool {
            let tolerance: CGFloat = 1
            return abs(frame.minX - visibleFrame.minX) <= tolerance
                && abs(frame.minY - visibleFrame.minY) <= tolerance
                && abs(frame.maxX - visibleFrame.maxX) <= tolerance
                && abs(frame.maxY - visibleFrame.maxY) <= tolerance
        }
    }
}

private struct ToolbarSVGIcon: View {
    let name: String
    let fallbackSystemImage: String

    var body: some View {
        Group {
            if let image = Self.load(name) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSystemImage)
                    .resizable()
                    .scaledToFit()
            }
        }
        .accessibilityHidden(true)
        .frame(width: 20, height: 20)
        .foregroundStyle(.primary)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }

    private static func load(_ name: String) -> NSImage? {
        let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "ToolbarIcons")
            ?? Bundle.module.url(forResource: name, withExtension: "svg")
        guard let url, let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = true
        return image
    }
}

private struct ProviderSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SetupErrorView {
            Task { await model.refreshProviders() }
        }
        .overlay(alignment: .topTrailing) {
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .padding(PremiumStyle.space16)
        }
        .frame(minWidth: 680, minHeight: 560)
    }
}

struct BannerView: View {
    private static let dismissalDelayNanoseconds: UInt64 = 8_000_000_000

    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(PremiumStyle.brand)
                .accessibilityHidden(true)
            Text(text)
                .font(.inter(.callout))
                .lineLimit(4)
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
            .accessibilityLabel("Dismiss message")
            .accessibilityIdentifier("dismiss-banner")
        }
        .padding(.horizontal, PremiumStyle.space16)
        .padding(.vertical, PremiumStyle.space12)
        .background(PremiumStyle.fieldFill, in: RoundedRectangle(cornerRadius: PremiumStyle.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PremiumStyle.cardRadius, style: .continuous)
                .strokeBorder(PremiumStyle.cardStroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 12, y: 3)
        .padding(.horizontal, PremiumStyle.space20)
        .frame(maxWidth: 560)
        .accessibilityElement(children: .contain)
        .task(id: text) {
            if let application = NSApp {
                NSAccessibility.post(
                    element: application,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: text,
                        .priority: NSAccessibilityPriorityLevel.medium.rawValue
                    ]
                )
            }
            do {
                try await Task.sleep(nanoseconds: Self.dismissalDelayNanoseconds)
            } catch {
                return
            }
            onDismiss()
        }
    }
}

private struct ProviderUnavailableBanner: View {
    let onSetup: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Your tools remain available, but creating or updating one needs a ready model provider.")
                .font(.inter(.callout))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Set Up…", action: onSetup)
                .controlSize(.small)
        }
        .padding(.horizontal, PremiumStyle.space16)
        .padding(.vertical, PremiumStyle.space12)
        .background(
            PremiumStyle.fieldFill,
            in: RoundedRectangle(cornerRadius: PremiumStyle.cardRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PremiumStyle.cardRadius, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 12, y: 3)
        .padding(.horizontal, PremiumStyle.space20)
        .frame(maxWidth: 620)
        .accessibilityElement(children: .contain)
    }
}
