import Combine
import Foundation
import UserNotifications

struct FailureTransitionTracker {
    private var healthByApplet: [UUID: Bool] = [:]

    mutating func record(id: UUID, healthy: Bool) -> Bool {
        let previous = healthByApplet[id]
        healthByApplet[id] = healthy
        return !healthy && previous != false
    }

    mutating func remove(id: UUID) {
        healthByApplet.removeValue(forKey: id)
    }
}

/// Interprets validated applet manifests and produces live menu bar snapshots.
@MainActor
final class AppletRuntimeEngine: ObservableObject {
    @Published private(set) var snapshots: [UUID: AppletSnapshot] = [:]

    private let shellApprovals: ShellApprovalStore
    private let generatedTools: GeneratedToolArtifactStore
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var timerEnds: [UUID: Date] = [:]
    private var timerPausedRemaining: [UUID: Int] = [:]
    private var metricCollectors: [UUID: SystemMetricsCollector] = [:]
    private var failureTransitions = FailureTransitionTracker()

    init(
        shellApprovals: ShellApprovalStore? = nil,
        generatedTools: GeneratedToolArtifactStore = GeneratedToolArtifactStore()
    ) {
        self.shellApprovals = shellApprovals ?? ShellApprovalStore()
        self.generatedTools = generatedTools
    }

    func sync(with manifests: [AppletManifest]) {
        let enabled = manifests.filter(\.enabled)
        let enabledIDs = Set(enabled.map(\.id))

        for id in tasks.keys where !enabledIDs.contains(id) {
            stop(id: id)
        }

        for manifest in enabled {
            if snapshots[manifest.id] == nil {
                snapshots[manifest.id] = .placeholder(for: manifest)
            }
            if tasks[manifest.id] == nil {
                start(manifest)
            }
        }
    }

    func restart(manifest: AppletManifest) {
        stop(id: manifest.id)
        guard manifest.enabled else {
            snapshots[manifest.id] = .placeholder(for: manifest)
            return
        }
        start(manifest)
    }

    func stop(id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        timerEnds[id] = nil
        timerPausedRemaining[id] = nil
        metricCollectors[id] = nil
        failureTransitions.remove(id: id)
    }

    func stopAll() {
        for id in Array(tasks.keys) {
            stop(id: id)
        }
    }

    func toggleTimer(id: UUID, manifest: AppletManifest) {
        guard manifest.kind == .timer || manifest.kind == .countdown else { return }
        if let end = timerEnds[id] {
            let remaining = max(0, Int(end.timeIntervalSinceNow))
            timerPausedRemaining[id] = remaining
            timerEnds[id] = nil
            updateTimerSnapshot(manifest: manifest, remaining: remaining, running: false)
        } else {
            let duration = manifest.config.durationSeconds ?? 1
            let remaining = Self.resumedTimerRemaining(
                pausedRemaining: timerPausedRemaining[id],
                duration: duration
            )
            timerEnds[id] = Date().addingTimeInterval(TimeInterval(remaining))
            timerPausedRemaining[id] = nil
            updateTimerSnapshot(manifest: manifest, remaining: remaining, running: true)
        }
    }

    func resetTimer(id: UUID, manifest: AppletManifest) {
        let duration = max(1, manifest.config.durationSeconds ?? 1)
        timerPausedRemaining[id] = nil
        timerEnds[id] = Date().addingTimeInterval(TimeInterval(duration))
        updateTimerSnapshot(manifest: manifest, remaining: duration, running: true)
    }

    static func resumedTimerRemaining(pausedRemaining: Int?, duration: Int) -> Int {
        let duration = max(1, duration)
        guard let pausedRemaining, pausedRemaining > 0 else { return duration }
        return pausedRemaining
    }

    // MARK: - Private

    private func start(_ manifest: AppletManifest) {
        AppLog.runtime.info("Starting applet \(manifest.name, privacy: .public) (\(manifest.kind.rawValue, privacy: .public))")

        switch manifest.kind {
        case .timer, .countdown:
            let duration = max(1, manifest.config.durationSeconds ?? 1)
            timerEnds[manifest.id] = Date().addingTimeInterval(TimeInterval(duration))
            timerPausedRemaining[manifest.id] = nil
            tasks[manifest.id] = Task { [weak self] in
                await self?.runTimerLoop(manifest)
            }
        default:
            if manifest.kind == .systemMetrics {
                metricCollectors[manifest.id] = SystemMetricsCollector()
            }
            tasks[manifest.id] = Task { [weak self] in
                await self?.runPollingLoop(manifest)
            }
        }
    }

    private func runTimerLoop(_ manifest: AppletManifest) async {
        while !Task.isCancelled {
            let remaining: Int
            let running: Bool
            if let end = timerEnds[manifest.id] {
                remaining = max(0, Int(ceil(end.timeIntervalSinceNow)))
                running = true
                if remaining == 0 {
                    updateTimerSnapshot(manifest: manifest, remaining: 0, running: false)
                    if manifest.notifyOnComplete {
                        notify(title: manifest.name, body: "Timer finished.")
                    }
                    if manifest.config.autoRestart == true {
                        let duration = max(1, manifest.config.durationSeconds ?? 1)
                        timerEnds[manifest.id] = Date().addingTimeInterval(TimeInterval(duration))
                    } else {
                        timerEnds[manifest.id] = nil
                        timerPausedRemaining[manifest.id] = 0
                    }
                } else {
                    updateTimerSnapshot(manifest: manifest, remaining: remaining, running: running)
                }
            } else {
                remaining = timerPausedRemaining[manifest.id] ?? manifest.config.durationSeconds ?? 1
                running = false
                updateTimerSnapshot(manifest: manifest, remaining: remaining, running: running)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func runPollingLoop(_ manifest: AppletManifest) async {
        let interval = max(1, manifest.refreshIntervalSeconds ?? manifest.kind.defaultRefreshInterval ?? 10)
        while !Task.isCancelled {
            await tick(manifest)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    private func tick(_ manifest: AppletManifest) async {
        switch manifest.kind {
        case .generatedTool:
            await tickGeneratedTool(manifest)
        case .timer, .countdown:
            break
        case .httpMonitor:
            await tickHTTP(manifest)
        case .portMonitor:
            await tickPort(manifest)
        case .systemMetrics:
            tickMetrics(manifest)
        case .gitStatus:
            await tickGit(manifest)
        case .shellCommand:
            await tickShell(manifest)
        }
    }

    private func tickHTTP(_ manifest: AppletManifest) async {
        let url = manifest.config.url ?? ""
        let timeout = manifest.config.timeoutSeconds ?? 5
        let result = await HTTPProbe.check(
            urlString: url,
            expectedStatusCode: manifest.config.expectedStatusCode,
            timeout: timeout
        )
        let values: [String: String] = [
            "status": result.ok ? "Online" : "Offline",
            "value": result.statusCode.map(String.init) ?? "—",
            "host": URL(string: url)?.host ?? url
        ]
        let title = TitleRenderer.render(template: manifest.titleTemplate, values: values, fallback: manifest.name)
        snapshots[manifest.id] = AppletSnapshot(
            statusText: result.message,
            title: title,
            detailLines: [
                url,
                "Latency \(result.latencyMS) ms",
                result.ok ? "Healthy" : "Check failed"
            ],
            isHealthy: result.ok,
            values: values,
            updatedAt: .now,
            isRunning: true,
            progress: nil
        )
        maybeNotifyFailure(manifest: manifest, healthy: result.ok, body: result.message)
    }

    private func tickPort(_ manifest: AppletManifest) async {
        let host = manifest.config.host ?? "127.0.0.1"
        let port = manifest.config.port ?? 0
        let timeout = manifest.config.timeoutSeconds ?? 2
        let open = await PortProbe.isOpen(host: host, port: port, timeout: timeout)
        let values: [String: String] = [
            "status": open ? "Online" : "Offline",
            "value": open ? "up" : "down",
            "host": host,
            "port": String(port)
        ]
        let title = TitleRenderer.render(template: manifest.titleTemplate, values: values, fallback: manifest.name)
        snapshots[manifest.id] = AppletSnapshot(
            statusText: open ? "Port \(port) open" : "Port \(port) closed",
            title: title,
            detailLines: ["\(host):\(port)", open ? "Accepting connections" : "Unreachable"],
            isHealthy: open,
            values: values,
            updatedAt: .now,
            isRunning: true,
            progress: nil
        )
        maybeNotifyFailure(manifest: manifest, healthy: open, body: "\(host):\(port) is offline")
    }

    private func tickMetrics(_ manifest: AppletManifest) {
        let metrics = manifest.config.metrics ?? [.cpu, .memory]
        let collector = metricCollectors[manifest.id] ?? SystemMetricsCollector()
        metricCollectors[manifest.id] = collector
        let cpu = collector.cpuUsagePercent()
        let memory = SystemMetricsCollector.memoryUsage()
        var values: [String: String] = [:]
        var details: [String] = []
        if metrics.contains(.cpu) {
            values["cpu"] = TitleRenderer.formatPercent(cpu)
            details.append("CPU \(TitleRenderer.formatPercent(cpu))")
        }
        if metrics.contains(.memory) {
            values["memory"] = TitleRenderer.formatPercent(memory.percent)
            values["value"] = TitleRenderer.formatBytes(memory.usedBytes)
            details.append("Memory \(TitleRenderer.formatPercent(memory.percent))")
            details.append(TitleRenderer.formatBytes(memory.usedBytes) + " used")
        }
        values["status"] = "Live"
        let title = TitleRenderer.render(template: manifest.titleTemplate, values: values, fallback: manifest.name)
        snapshots[manifest.id] = AppletSnapshot(
            statusText: details.joined(separator: " · "),
            title: title,
            detailLines: details,
            isHealthy: true,
            values: values,
            updatedAt: .now,
            isRunning: true,
            progress: nil
        )
    }

    private func tickGit(_ manifest: AppletManifest) async {
        let path = manifest.config.repositoryPath ?? ""
        let result = await GitStatusProbe.probe(repositoryPath: path)
        let values: [String: String] = [
            "status": result.ok ? "OK" : "Error",
            "branch": result.branch,
            "changes": String(result.changedFiles),
            "value": String(result.changedFiles)
        ]
        let title = TitleRenderer.render(template: manifest.titleTemplate, values: values, fallback: manifest.name)
        snapshots[manifest.id] = AppletSnapshot(
            statusText: result.message,
            title: title,
            detailLines: [
                (path as NSString).expandingTildeInPath,
                "Branch \(result.branch)",
                "\(result.changedFiles) changed files"
            ],
            isHealthy: result.ok,
            values: values,
            updatedAt: .now,
            isRunning: true,
            progress: nil
        )
        maybeNotifyFailure(manifest: manifest, healthy: result.ok, body: result.message)
    }

    private func tickShell(_ manifest: AppletManifest) async {
        let command = manifest.config.command ?? ""
        let approved = shellApprovals.isApproved(manifest)
        let result = await ShellCommandProbe.run(
            command: command,
            workingDirectory: manifest.config.workingDirectory,
            approved: approved
        )
        let values: [String: String] = [
            "status": result.ok ? "OK" : "Error",
            "value": result.message
        ]
        let title = TitleRenderer.render(template: manifest.titleTemplate, values: values, fallback: manifest.name)
        snapshots[manifest.id] = AppletSnapshot(
            statusText: result.message,
            title: title,
            detailLines: [
                command,
                result.ok ? "Exit \(result.exitCode)" : result.message,
                approved ? "Approved" : "Awaiting approval"
            ],
            isHealthy: result.ok,
            values: values,
            updatedAt: .now,
            isRunning: approved,
            progress: nil
        )
        maybeNotifyFailure(manifest: manifest, healthy: result.ok || !approved, body: result.message)
    }

    private func tickGeneratedTool(_ manifest: AppletManifest) async {
        let approved = shellApprovals.isApproved(manifest)
        let result = await GeneratedToolRunner.run(
            manifest: manifest,
            approved: approved,
            artifactStore: generatedTools
        )

        if let output = result.output {
            var values = output.values
            values["status"] = values["status"] ?? output.status
            values["value"] = values["value"] ?? output.title
            snapshots[manifest.id] = AppletSnapshot(
                statusText: output.status,
                title: output.title,
                detailLines: output.details.isEmpty ? ["Generated tool is running"] : output.details,
                isHealthy: output.healthy,
                values: values,
                updatedAt: .now,
                isRunning: true,
                progress: nil
            )
            maybeNotifyFailure(manifest: manifest, healthy: output.healthy, body: output.status)
        } else {
            let title = result.approved ? "Issue" : "Review"
            snapshots[manifest.id] = AppletSnapshot(
                statusText: result.message,
                title: title,
                detailLines: [
                    result.approved ? "Generated code could not refresh" : "Generated code is installed",
                    result.approved ? result.message : "Open Bar Tender to review and allow it"
                ],
                isHealthy: !result.approved,
                values: ["status": result.approved ? "Error" : "Ready", "value": title],
                updatedAt: .now,
                isRunning: false,
                progress: nil
            )
            maybeNotifyFailure(manifest: manifest, healthy: !result.approved, body: result.message)
        }
    }

    private func updateTimerSnapshot(manifest: AppletManifest, remaining: Int, running: Bool) {
        let duration = max(1, manifest.config.durationSeconds ?? 1)
        let values: [String: String] = [
            "remaining": TitleRenderer.formatDuration(remaining),
            "status": running ? "Running" : (remaining == 0 ? "Done" : "Paused"),
            "value": TitleRenderer.formatDuration(remaining)
        ]
        let title = TitleRenderer.render(template: manifest.titleTemplate, values: values, fallback: manifest.name)
        snapshots[manifest.id] = AppletSnapshot(
            statusText: running ? "Running" : (remaining == 0 ? "Completed" : "Paused"),
            title: title,
            detailLines: [
                "Duration \(TitleRenderer.formatDuration(duration))",
                "Remaining \(TitleRenderer.formatDuration(remaining))"
            ],
            isHealthy: true,
            values: values,
            updatedAt: .now,
            isRunning: running,
            progress: 1.0 - (Double(remaining) / Double(duration))
        )
    }

    private func maybeNotifyFailure(manifest: AppletManifest, healthy: Bool, body: String) {
        let shouldNotify = failureTransitions.record(id: manifest.id, healthy: healthy)
        guard manifest.notifyOnFailure, shouldNotify else { return }
        notify(title: manifest.name, body: body)
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
