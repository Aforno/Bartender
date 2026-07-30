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

/// Issues monotonically increasing tokens for each applet execution.
///
/// A cancelled probe may still return a normal value (for example, a Network
/// continuation can finish after its parent task is cancelled). The token and
/// captured manifest together prevent that old result from publishing into a
/// restarted or same-UUID replacement tool.
struct AppletExecutionEpochs {
    private var epochs: [UUID: UInt64] = [:]

    mutating func begin(for id: UUID) -> UInt64 {
        let next = (epochs[id] ?? 0) &+ 1
        let epoch = next == 0 ? 1 : next
        epochs[id] = epoch
        return epoch
    }

    mutating func invalidate(_ id: UUID) {
        _ = begin(for: id)
    }

    func accepts(
        _ epoch: UInt64,
        manifest: AppletManifest,
        currentManifest: AppletManifest?
    ) -> Bool {
        epochs[manifest.id] == epoch && currentManifest == manifest
    }
}

enum AppletTimerLoopDisposition: Equatable {
    case idle
    case running(remaining: Int)
    case completed
}

/// Interprets validated applet manifests and produces live menu bar snapshots.
@MainActor
final class AppletRuntimeEngine: ObservableObject {
    @Published private(set) var snapshots: [UUID: AppletSnapshot] = [:]

    private let shellApprovals: ShellApprovalStore
    private let generatedTools: GeneratedToolArtifactStore
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Manifest last captured into each running task. Used so `sync` can restart
    /// same-UUID tools when import/edit changes content without changing the id.
    private var startedManifests: [UUID: AppletManifest] = [:]
    private var timerEnds: [UUID: Date] = [:]
    private var timerPausedRemaining: [UUID: Int] = [:]
    private var metricCollectors: [UUID: SystemMetricsCollector] = [:]
    private var failureTransitions = FailureTransitionTracker()
    private var executionEpochs = AppletExecutionEpochs()

    /// Useful for lifecycle diagnostics and deterministic regression tests.
    var activeExecutionIDs: Set<UUID> {
        Set(tasks.keys)
    }

    init(
        shellApprovals: ShellApprovalStore? = nil,
        generatedTools: GeneratedToolArtifactStore = GeneratedToolArtifactStore()
    ) {
        self.shellApprovals = shellApprovals ?? ShellApprovalStore()
        self.generatedTools = generatedTools
    }

    func sync(with manifests: [AppletManifest]) {
        let manifestIDs = Set(manifests.map(\.id))
        let enabled = manifests.filter(\.enabled)
        let enabledIDs = Set(enabled.map(\.id))
        let trackedIDs = Set(tasks.keys).union(startedManifests.keys)

        for id in trackedIDs where !enabledIDs.contains(id) {
            stop(id: id)
        }

        for manifest in manifests where !manifest.enabled {
            snapshots[manifest.id] = .placeholder(for: manifest)
        }

        for id in Array(snapshots.keys) where !manifestIDs.contains(id) {
            snapshots.removeValue(forKey: id)
            failureTransitions.remove(id: id)
        }

        for manifest in enabled {
            if snapshots[manifest.id] == nil {
                snapshots[manifest.id] = .placeholder(for: manifest)
            }
            if startedManifests[manifest.id] == nil {
                start(manifest)
            } else if startedManifests[manifest.id] != manifest {
                // Same UUID but content changed (e.g. library import/merge).
                // Restart so the polling loop captures the new manifest.
                restart(manifest: manifest)
            }
        }
    }

    func restart(manifest: AppletManifest) {
        stop(id: manifest.id)
        snapshots[manifest.id] = .placeholder(for: manifest)
        guard manifest.enabled else {
            return
        }
        start(manifest)
    }

    /// Publishes the already-observed approval check and schedules the next refresh normally,
    /// avoiding an immediate duplicate execution of the generated program.
    func startValidatedGeneratedTool(
        manifest: AppletManifest,
        output: GeneratedToolOutput
    ) {
        stop(id: manifest.id)
        guard manifest.enabled else {
            snapshots[manifest.id] = .placeholder(for: manifest)
            return
        }
        startedManifests[manifest.id] = manifest
        let epoch = executionEpochs.begin(for: manifest.id)
        applyGeneratedToolOutput(output, manifest: manifest)
        tasks[manifest.id] = Task { [weak self] in
            await self?.runPollingLoop(manifest, epoch: epoch, delayFirstTick: true)
        }
    }

    func stop(id: UUID) {
        executionEpochs.invalidate(id)
        tasks[id]?.cancel()
        tasks[id] = nil
        startedManifests[id] = nil
        timerEnds[id] = nil
        timerPausedRemaining[id] = nil
        metricCollectors[id] = nil
        failureTransitions.remove(id: id)
    }

    func stopAll() {
        let trackedIDs = Set(tasks.keys)
            .union(startedManifests.keys)
            .union(snapshots.keys)
        for id in trackedIDs {
            stop(id: id)
        }
        snapshots.removeAll()
    }

    func toggleTimer(id: UUID, manifest: AppletManifest) {
        guard manifest.enabled,
              manifest.kind == .timer || manifest.kind == .countdown else { return }
        guard startedManifests[id] == manifest else {
            restart(manifest: manifest)
            return
        }

        if let end = timerEnds[id] {
            let remaining = max(0, Int(end.timeIntervalSinceNow))
            timerPausedRemaining[id] = remaining
            timerEnds[id] = nil
            suspendExecutionTask(id: id)
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
            scheduleTimerLoop(manifest)
        }
    }

    func resetTimer(id: UUID, manifest: AppletManifest) {
        guard manifest.enabled,
              manifest.kind == .timer || manifest.kind == .countdown else { return }
        guard startedManifests[id] == manifest else {
            restart(manifest: manifest)
            return
        }

        let duration = max(1, manifest.config.durationSeconds ?? 1)
        timerPausedRemaining[id] = nil
        timerEnds[id] = Date().addingTimeInterval(TimeInterval(duration))
        updateTimerSnapshot(manifest: manifest, remaining: duration, running: true)
        scheduleTimerLoop(manifest)
    }

    static func resumedTimerRemaining(pausedRemaining: Int?, duration: Int) -> Int {
        let duration = max(1, duration)
        guard let pausedRemaining, pausedRemaining > 0 else { return duration }
        return pausedRemaining
    }

    static func timerLoopDisposition(
        timerEnd: Date?,
        now: Date
    ) -> AppletTimerLoopDisposition {
        guard let timerEnd else { return .idle }
        let remaining = max(0, Int(ceil(timerEnd.timeIntervalSince(now))))
        return remaining == 0 ? .completed : .running(remaining: remaining)
    }

    // MARK: - Private

    private func start(_ manifest: AppletManifest) {
        AppLog.runtime.info("Starting applet \(manifest.name, privacy: .public) (\(manifest.kind.rawValue, privacy: .public))")
        startedManifests[manifest.id] = manifest

        switch manifest.kind {
        case .timer, .countdown:
            let duration = max(1, manifest.config.durationSeconds ?? 1)
            timerEnds[manifest.id] = Date().addingTimeInterval(TimeInterval(duration))
            timerPausedRemaining[manifest.id] = nil
            updateTimerSnapshot(manifest: manifest, remaining: duration, running: true)
            scheduleTimerLoop(manifest)
        default:
            if manifest.kind == .systemMetrics {
                metricCollectors[manifest.id] = SystemMetricsCollector()
            }
            let epoch = executionEpochs.begin(for: manifest.id)
            tasks[manifest.id] = Task { [weak self] in
                await self?.runPollingLoop(manifest, epoch: epoch)
            }
        }
    }

    private func scheduleTimerLoop(_ manifest: AppletManifest) {
        tasks[manifest.id]?.cancel()
        let epoch = executionEpochs.begin(for: manifest.id)
        tasks[manifest.id] = Task { [weak self] in
            await self?.runTimerLoop(manifest, epoch: epoch)
        }
    }

    private func suspendExecutionTask(id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        executionEpochs.invalidate(id)
    }

    private func finishTimerLoopIfCurrent(
        manifest: AppletManifest,
        epoch: UInt64
    ) {
        guard executionEpochs.accepts(
            epoch,
            manifest: manifest,
            currentManifest: startedManifests[manifest.id]
        ) else { return }
        tasks[manifest.id] = nil
    }

    private func runTimerLoop(
        _ manifest: AppletManifest,
        epoch: UInt64
    ) async {
        while canPublish(manifest: manifest, epoch: epoch) {
            switch Self.timerLoopDisposition(
                timerEnd: timerEnds[manifest.id],
                now: .now
            ) {
            case .idle:
                finishTimerLoopIfCurrent(manifest: manifest, epoch: epoch)
                return

            case .completed:
                guard canPublish(manifest: manifest, epoch: epoch) else { return }
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
                    finishTimerLoopIfCurrent(manifest: manifest, epoch: epoch)
                    return
                }

            case .running(let remaining):
                guard canPublish(manifest: manifest, epoch: epoch) else { return }
                updateTimerSnapshot(manifest: manifest, remaining: remaining, running: true)
            }

            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
        }
    }

    private func runPollingLoop(
        _ manifest: AppletManifest,
        epoch: UInt64,
        delayFirstTick: Bool = false
    ) async {
        let interval = max(1, manifest.refreshIntervalSeconds ?? manifest.kind.defaultRefreshInterval ?? 10)
        if delayFirstTick {
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                return
            }
        }
        while canPublish(manifest: manifest, epoch: epoch) {
            await tick(manifest, epoch: epoch)
            guard canPublish(manifest: manifest, epoch: epoch) else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                return
            }
        }
    }

    private func canPublish(
        manifest: AppletManifest,
        epoch: UInt64
    ) -> Bool {
        !Task.isCancelled && executionEpochs.accepts(
            epoch,
            manifest: manifest,
            currentManifest: startedManifests[manifest.id]
        )
    }

    private func tick(_ manifest: AppletManifest, epoch: UInt64) async {
        switch manifest.kind {
        case .generatedTool:
            await tickGeneratedTool(manifest, epoch: epoch)
        case .timer, .countdown:
            break
        case .httpMonitor:
            await tickHTTP(manifest, epoch: epoch)
        case .portMonitor:
            await tickPort(manifest, epoch: epoch)
        case .systemMetrics:
            tickMetrics(manifest, epoch: epoch)
        case .gitStatus:
            await tickGit(manifest, epoch: epoch)
        case .shellCommand:
            await tickShell(manifest, epoch: epoch)
        }
    }

    private func tickHTTP(_ manifest: AppletManifest, epoch: UInt64) async {
        let url = manifest.config.url ?? ""
        let timeout = manifest.config.timeoutSeconds ?? 5
        let result = await HTTPProbe.check(
            urlString: url,
            expectedStatusCode: manifest.config.expectedStatusCode,
            timeout: timeout
        )
        guard canPublish(manifest: manifest, epoch: epoch) else { return }
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

    private func tickPort(_ manifest: AppletManifest, epoch: UInt64) async {
        let host = manifest.config.host ?? "127.0.0.1"
        let port = manifest.config.port ?? 0
        let timeout = manifest.config.timeoutSeconds ?? 2
        let open = await PortProbe.isOpen(host: host, port: port, timeout: timeout)
        guard canPublish(manifest: manifest, epoch: epoch) else { return }
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

    private func tickMetrics(_ manifest: AppletManifest, epoch: UInt64) {
        guard canPublish(manifest: manifest, epoch: epoch) else { return }
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

    private func tickGit(_ manifest: AppletManifest, epoch: UInt64) async {
        let path = manifest.config.repositoryPath ?? ""
        let result = await GitStatusProbe.probe(repositoryPath: path)
        guard canPublish(manifest: manifest, epoch: epoch) else { return }
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

    private func tickShell(_ manifest: AppletManifest, epoch: UInt64) async {
        let command = manifest.config.command ?? ""
        let approved = shellApprovals.isApproved(manifest)
        let result = await ShellCommandProbe.run(
            command: command,
            workingDirectory: manifest.config.workingDirectory,
            approved: approved
        )
        guard canPublish(manifest: manifest, epoch: epoch) else { return }
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

    private func tickGeneratedTool(_ manifest: AppletManifest, epoch: UInt64) async {
        let approved = shellApprovals.isApproved(manifest)
        let result = await GeneratedToolRunner.run(
            manifest: manifest,
            approved: approved,
            artifactStore: generatedTools
        )
        guard canPublish(manifest: manifest, epoch: epoch) else { return }

        if let output = result.output {
            applyGeneratedToolOutput(output, manifest: manifest)
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

    private func applyGeneratedToolOutput(
        _ output: GeneratedToolOutput,
        manifest: AppletManifest
    ) {
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
