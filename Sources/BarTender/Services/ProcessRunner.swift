import Foundation

struct ProcessResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
    var cancelled: Bool
}

enum ProcessRunnerError: LocalizedError {
    case launchFailed(String)
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .launchFailed(let detail):
            return "Failed to launch process: \(detail)"
        case .timedOut:
            return "Process timed out."
        case .cancelled:
            return "Process was cancelled."
        }
    }
}

/// Runs external processes with stdout/stderr capture, timeout, and cancellation.
actor ProcessRunner {
    private struct ActiveProcess {
        var process: Process
        var cancelledFlag: LockedFlag
    }

    private var activeProcesses: [UUID: ActiveProcess] = [:]

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: String? = nil,
        timeout: TimeInterval? = nil,
        onStdout: (@Sendable (String) -> Void)? = nil,
        onStderr: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        let terminationWaiter = ProcessTerminationWaiter()
        process.terminationHandler = { _ in
            terminationWaiter.signal()
        }

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }
        // The child owns duplicated write descriptors after launch. Closing the
        // parent's copies lets the readers observe EOF when the child exits.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        // Dedicated blocking readers avoid racing FileHandle readability callbacks
        // against teardown and still drain stdout/stderr concurrently.
        let stdoutTask = Task.detached(priority: .utility) {
            collectProcessOutput(from: stdoutPipe.fileHandleForReading, onChunk: onStdout)
        }
        let stderrTask = Task.detached(priority: .utility) {
            collectProcessOutput(from: stderrPipe.fileHandleForReading, onChunk: onStderr)
        }

        let invocationID = UUID()
        let timedOutFlag = LockedFlag()
        let cancelledFlag = LockedFlag()
        activeProcesses[invocationID] = ActiveProcess(
            process: process,
            cancelledFlag: cancelledFlag
        )
        var timeoutTask: Task<Void, Never>?

        if let timeout {
            timeoutTask = Task { [weak process] in
                let ns = UInt64(timeout * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                guard !Task.isCancelled else { return }
                if let process, process.isRunning {
                    timedOutFlag.set()
                    process.terminate()
                    // Escalate if needed.
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if process.isRunning {
                        process.interrupt()
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }

        await withTaskCancellationHandler {
            await terminationWaiter.wait()
        } onCancel: {
            cancelledFlag.set()
            process.terminate()
        }

        timeoutTask?.cancel()
        activeProcesses.removeValue(forKey: invocationID)

        let stdout = String(data: await stdoutTask.value, encoding: .utf8) ?? ""
        let stderr = String(data: await stderrTask.value, encoding: .utf8) ?? ""

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOutFlag.value,
            cancelled: cancelledFlag.value || Task.isCancelled
        )
    }

    func cancel() {
        for active in activeProcesses.values where active.process.isRunning {
            active.cancelledFlag.set()
            active.process.terminate()
        }
    }
}

private final class ProcessTerminationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        lock.lock()
        finished = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

private func collectProcessOutput(
    from handle: FileHandle,
    onChunk: (@Sendable (String) -> Void)?
) -> Data {
    var collected = Data()
    do {
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            collected.append(chunk)
            if let onChunk, let text = String(data: chunk, encoding: .utf8) {
                onChunk(text)
            }
        }
    } catch {
        // A closed pipe after process termination is equivalent to EOF. The
        // process result still carries its exit status and any captured bytes.
    }
    return collected
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}
