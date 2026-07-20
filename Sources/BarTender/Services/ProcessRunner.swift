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

        let stdoutData = LockedData()
        let stderrData = LockedData()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stdoutData.append(chunk)
            if let onStdout, let text = String(data: chunk, encoding: .utf8) {
                onStdout(text)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrData.append(chunk)
            if let onStderr, let text = String(data: chunk, encoding: .utf8) {
                onStderr(text)
            }
        }

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
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
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
            }
        } onCancel: {
            cancelledFlag.set()
            process.terminate()
        }

        timeoutTask?.cancel()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        activeProcesses.removeValue(forKey: invocationID)

        // Drain remaining bytes.
        let remainingOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let remainingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingOut.isEmpty {
            stdoutData.append(remainingOut)
            if let onStdout, let text = String(data: remainingOut, encoding: .utf8) {
                onStdout(text)
            }
        }
        if !remainingErr.isEmpty {
            stderrData.append(remainingErr)
            if let onStderr, let text = String(data: remainingErr, encoding: .utf8) {
                onStderr(text)
            }
        }

        let stdout = String(data: stdoutData.data, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData.data, encoding: .utf8) ?? ""

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

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ chunk: Data) {
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }
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
