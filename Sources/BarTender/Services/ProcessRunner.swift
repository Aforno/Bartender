import Darwin
import Dispatch
import Foundation

struct ProcessResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
    var cancelled: Bool
    /// True when the corresponding captured string contains only the bounded
    /// beginning and end of the process output, separated by
    /// `ProcessRunner.outputTruncationMarker`.
    var stdoutTruncated: Bool
    var stderrTruncated: Bool

    init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        timedOut: Bool,
        cancelled: Bool,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }
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
    /// Maximum source bytes retained independently for stdout and stderr.
    /// Streaming callbacks still receive every chunk while the process is alive.
    static let maximumRetainedOutputBytes = 1_048_576
    static let outputTruncationMarker = "\n[... Bar Tender output truncated ...]\n"

    private struct ActiveProcess {
        var processIdentifier: pid_t
        var cancelledFlag: LockedFlag
        var parentTerminatedFlag: LockedFlag
    }

    private struct SpawnedProcess: Sendable {
        var processIdentifier: pid_t
        var stdoutDescriptor: Int32
        var stderrDescriptor: Int32
    }

    private struct WaitResult: Sendable {
        var exitCode: Int32
    }

    fileprivate struct CollectedOutput: Sendable {
        var text: String
        var truncated: Bool
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
        let launchCancellation = SpawnCancellationState()

        return try await withTaskCancellationHandler {
            guard !Task.isCancelled else {
                throw ProcessRunnerError.cancelled
            }

            do {
                // Children start suspended. Register the pid with the outer
                // cancellation handler before allowing any command code to run.
                let process = try Self.spawn(
                    executable: executable,
                    arguments: arguments,
                    environment: environment,
                    currentDirectory: currentDirectory
                )
                let cancelledBeforeResume =
                    launchCancellation.register(process.processIdentifier)
                    || Task.isCancelled
                if cancelledBeforeResume {
                    Self.forceTerminate(processIdentifier: process.processIdentifier)
                } else if Darwin.kill(process.processIdentifier, SIGCONT) != 0 {
                    let resumeError = errno
                    Self.forceTerminate(processIdentifier: process.processIdentifier)
                    _ = try? await runSpawnedProcess(
                        process,
                        timeout: nil,
                        onStdout: nil,
                        onStderr: nil,
                        launchCancellation: launchCancellation
                    )
                    throw ProcessRunnerError.launchFailed(
                        "resume process: \(Self.posixError(resumeError))"
                    )
                }

                return try await runSpawnedProcess(
                    process,
                    timeout: timeout,
                    onStdout: onStdout,
                    onStderr: onStderr,
                    launchCancellation: launchCancellation
                )
            } catch {
                if Task.isCancelled {
                    throw ProcessRunnerError.cancelled
                }
                if let runnerError = error as? ProcessRunnerError {
                    throw runnerError
                }
                throw ProcessRunnerError.launchFailed(error.localizedDescription)
            }
        } onCancel: {
            if let processIdentifier = launchCancellation.cancel() {
                // This handler owns only the short launch-to-monitoring gap.
                // Once monitoring is installed, its cancellation handler takes
                // over with TERM→KILL escalation.
                Self.forceTerminate(processIdentifier: processIdentifier)
            }
        }
    }

    private func runSpawnedProcess(
        _ process: SpawnedProcess,
        timeout: TimeInterval?,
        onStdout: (@Sendable (String) -> Void)?,
        onStderr: (@Sendable (String) -> Void)?,
        launchCancellation: SpawnCancellationState
    ) async throws -> ProcessResult {
        let parentTerminatedFlag = LockedFlag()
        // Cooperative tasks only: never block a concurrency-pool thread with
        // waitpid/poll. On small CI runners those blocked workers starve the
        // timeout/cancellation tasks and the suite hangs until job timeout.
        let stdoutTask = Task {
            await collectProcessOutput(
                from: process.stdoutDescriptor,
                parentTerminated: parentTerminatedFlag,
                onChunk: onStdout
            )
        }
        let stderrTask = Task {
            await collectProcessOutput(
                from: process.stderrDescriptor,
                parentTerminated: parentTerminatedFlag,
                onChunk: onStderr
            )
        }
        let waitTask = Task {
            await Self.waitForTermination(of: process.processIdentifier)
        }

        let invocationID = UUID()
        let timedOutFlag = LockedFlag()
        let cancelledFlag = LockedFlag()
        activeProcesses[invocationID] = ActiveProcess(
            processIdentifier: process.processIdentifier,
            cancelledFlag: cancelledFlag,
            parentTerminatedFlag: parentTerminatedFlag
        )
        var timeoutTask: Task<Void, Never>?

        if let timeout {
            timeoutTask = Task {
                let nanoseconds = Self.timeoutNanoseconds(timeout)
                guard nanoseconds > 0 else {
                    timedOutFlag.set()
                    Self.scheduleTerminateEscalating(
                        processIdentifier: process.processIdentifier,
                        parentTerminated: parentTerminatedFlag
                    )
                    return
                }
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                if !parentTerminatedFlag.value {
                    timedOutFlag.set()
                    Self.scheduleTerminateEscalating(
                        processIdentifier: process.processIdentifier,
                        parentTerminated: parentTerminatedFlag
                    )
                }
            }
        }

        // A cancellation that lands after this clear is already reflected in
        // Task.isCancelled, so entering the handler below invokes onCancel.
        launchCancellation.clear(process.processIdentifier)
        let waitResult = await withTaskCancellationHandler {
            await waitTask.value
        } onCancel: {
            cancelledFlag.set()
            Self.scheduleTerminateEscalating(
                processIdentifier: process.processIdentifier,
                parentTerminated: parentTerminatedFlag
            )
        }

        // Readers use this to stop after draining currently available bytes.
        // They do not wait for EOF because a surviving descendant may still own
        // a duplicated write descriptor.
        parentTerminatedFlag.set()
        timeoutTask?.cancel()
        activeProcesses.removeValue(forKey: invocationID)
        Self.scheduleDescendantCleanup(processIdentifier: process.processIdentifier)

        let stdout = await stdoutTask.value
        let stderr = await stderrTask.value

        return ProcessResult(
            exitCode: waitResult.exitCode,
            stdout: stdout.text,
            stderr: stderr.text,
            timedOut: timedOutFlag.value,
            cancelled: cancelledFlag.value || Task.isCancelled,
            stdoutTruncated: stdout.truncated,
            stderrTruncated: stderr.truncated
        )
    }

    func cancel() {
        for active in activeProcesses.values where !active.parentTerminatedFlag.value {
            active.cancelledFlag.set()
            Self.scheduleTerminateEscalating(
                processIdentifier: active.processIdentifier,
                parentTerminated: active.parentTerminatedFlag
            )
        }
    }

    private static func timeoutNanoseconds(_ timeout: TimeInterval) -> UInt64 {
        guard timeout.isFinite, timeout > 0 else { return 0 }
        let maximumSeconds = Double(UInt64.max) / 1_000_000_000
        return UInt64(min(timeout, maximumSeconds) * 1_000_000_000)
    }

    /// Every child starts in a process group whose id is the launched pid. Group
    /// signaling therefore reaches ordinary descendants without ever touching
    /// Bar Tender's own process group.
    private static func scheduleTerminateEscalating(
        processIdentifier: pid_t,
        parentTerminated: LockedFlag
    ) {
        signalProcessGroup(processIdentifier, signal: SIGTERM)
        if !parentTerminated.value {
            _ = Darwin.kill(processIdentifier, SIGTERM)
        }

        // Use GCD so escalation does not depend on the cooperative thread pool
        // (which may already be busy with process I/O or wait loops).
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            signalProcessGroup(processIdentifier, signal: SIGKILL)
            if !parentTerminated.value {
                _ = Darwin.kill(processIdentifier, SIGKILL)
            }
        }
    }

    /// A one-shot process may exit after leaving background descendants alive.
    /// Stop anything still in its isolated group without delaying the result.
    private static func scheduleDescendantCleanup(processIdentifier: pid_t) {
        signalProcessGroup(processIdentifier, signal: SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            signalProcessGroup(processIdentifier, signal: SIGKILL)
        }
    }

    private static func signalProcessGroup(_ processIdentifier: pid_t, signal: Int32) {
        guard processIdentifier > 1 else { return }
        _ = Darwin.kill(-processIdentifier, signal)
    }

    private static func forceTerminate(processIdentifier: pid_t) {
        guard processIdentifier > 1 else { return }
        signalProcessGroup(processIdentifier, signal: SIGKILL)
        _ = Darwin.kill(processIdentifier, SIGKILL)
    }

    /// Number of trailing bytes that form an incomplete UTF-8 sequence (0–3).
    /// Used to avoid lossy-decoding a character split across read() boundaries.
    static func incompleteUTF8SuffixLength(of data: Data) -> Int {
        var continuationCount = 0
        var leadByte: UInt8?
        for byte in data.suffix(4).reversed() {
            if byte & 0xC0 == 0x80 {
                continuationCount += 1
            } else {
                leadByte = byte
                break
            }
        }
        guard let lead = leadByte else { return 0 }
        let expectedLength: Int
        if lead & 0x80 == 0 {
            expectedLength = 1
        } else if lead & 0xE0 == 0xC0 {
            expectedLength = 2
        } else if lead & 0xF0 == 0xE0 {
            expectedLength = 3
        } else if lead & 0xF8 == 0xF0 {
            expectedLength = 4
        } else {
            return 0 // Invalid lead byte; decode as-is.
        }
        let available = continuationCount + 1
        return available < expectedLength ? available : 0
    }

    /// Cooperative wait so timeout/cancellation tasks stay schedulable.
    private static func waitForTermination(of processIdentifier: pid_t) async -> WaitResult {
        var status: Int32 = 0
        while true {
            let result = Darwin.waitpid(processIdentifier, &status, WNOHANG)
            if result == processIdentifier {
                let terminationSignal = status & 0x7f
                // Report signal deaths with the conventional 128+signal code so a
                // killed process is not mistaken for a real small exit status.
                let exitCode = terminationSignal == 0
                    ? (status >> 8) & 0xff
                    : 128 + terminationSignal
                return WaitResult(exitCode: exitCode)
            }
            if result == 0 {
                try? await Task.sleep(nanoseconds: 10_000_000)
                continue
            }
            if result == -1, errno == EINTR {
                continue
            }
            return WaitResult(exitCode: -1)
        }
    }

    private static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String?
    ) throws -> SpawnedProcess {
        var stdoutDescriptors: [Int32] = [-1, -1]
        var stderrDescriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&stdoutDescriptors) == 0 else {
            throw ProcessRunnerError.launchFailed(Self.posixError(errno))
        }
        guard Darwin.pipe(&stderrDescriptors) == 0 else {
            let error = errno
            Self.closeDescriptor(stdoutDescriptors[0])
            Self.closeDescriptor(stdoutDescriptors[1])
            throw ProcessRunnerError.launchFailed(Self.posixError(error))
        }

        defer {
            for descriptor in stdoutDescriptors + stderrDescriptors {
                Self.closeDescriptor(descriptor)
            }
        }

        var fileActions: posix_spawn_file_actions_t?
        try checkPOSIX(
            posix_spawn_file_actions_init(&fileActions),
            operation: "initialize process file actions"
        )
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        try checkPOSIX(
            posix_spawn_file_actions_adddup2(&fileActions, stdoutDescriptors[1], STDOUT_FILENO),
            operation: "connect process stdout"
        )
        try checkPOSIX(
            posix_spawn_file_actions_adddup2(&fileActions, stderrDescriptors[1], STDERR_FILENO),
            operation: "connect process stderr"
        )
        try checkPOSIX(
            posix_spawn_file_actions_addclose(&fileActions, stdoutDescriptors[0]),
            operation: "close child stdout reader"
        )
        try checkPOSIX(
            posix_spawn_file_actions_addclose(&fileActions, stderrDescriptors[0]),
            operation: "close child stderr reader"
        )
        try checkPOSIX(
            "/dev/null".withCString {
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDIN_FILENO,
                    $0,
                    O_RDONLY,
                    0
                )
            },
            operation: "connect process stdin"
        )
        if let currentDirectory {
            try checkPOSIX(
                currentDirectory.withCString {
                    posix_spawn_file_actions_addchdir(&fileActions, $0)
                },
                operation: "set process working directory"
            )
        }

        var attributes: posix_spawnattr_t?
        try checkPOSIX(
            posix_spawnattr_init(&attributes),
            operation: "initialize process attributes"
        )
        defer { posix_spawnattr_destroy(&attributes) }

        let flags = Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_START_SUSPENDED
        )
        try checkPOSIX(
            posix_spawnattr_setflags(&attributes, flags),
            operation: "set process spawn flags"
        )
        try checkPOSIX(
            posix_spawnattr_setpgroup(&attributes, 0),
            operation: "isolate process group"
        )

        var argv = try makeCStringArray([executable] + arguments)
        defer { freeCStringArray(argv) }

        let resolvedEnvironment = environment ?? ProcessInfo.processInfo.environment
        let environmentEntries = resolvedEnvironment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var envp = try makeCStringArray(environmentEntries)
        defer { freeCStringArray(envp) }

        var processIdentifier: pid_t = 0
        let spawnResult = executable.withCString { executablePointer in
            argv.withUnsafeMutableBufferPointer { argvBuffer in
                envp.withUnsafeMutableBufferPointer { environmentBuffer in
                    posix_spawn(
                        &processIdentifier,
                        executablePointer,
                        &fileActions,
                        &attributes,
                        argvBuffer.baseAddress,
                        environmentBuffer.baseAddress
                    )
                }
            }
        }
        try checkPOSIX(spawnResult, operation: "launch process")

        Self.closeDescriptor(stdoutDescriptors[1])
        stdoutDescriptors[1] = -1
        Self.closeDescriptor(stderrDescriptors[1])
        stderrDescriptors[1] = -1

        let process = SpawnedProcess(
            processIdentifier: processIdentifier,
            stdoutDescriptor: stdoutDescriptors[0],
            stderrDescriptor: stderrDescriptors[0]
        )
        stdoutDescriptors[0] = -1
        stderrDescriptors[0] = -1
        return process
    }

    private static func checkPOSIX(_ result: Int32, operation: String) throws {
        guard result == 0 else {
            throw ProcessRunnerError.launchFailed("\(operation): \(posixError(result))")
        }
    }

    private static func posixError(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    private static func closeDescriptor(_ descriptor: Int32) {
        guard descriptor >= 0 else { return }
        _ = Darwin.close(descriptor)
    }

    private static func makeCStringArray(
        _ strings: [String]
    ) throws -> [UnsafeMutablePointer<CChar>?] {
        var result: [UnsafeMutablePointer<CChar>?] = []
        result.reserveCapacity(strings.count + 1)
        for string in strings {
            guard let pointer = strdup(string) else {
                freeCStringArray(result)
                throw ProcessRunnerError.launchFailed("Could not allocate process arguments.")
            }
            result.append(pointer)
        }
        result.append(nil)
        return result
    }

    private static func freeCStringArray(_ pointers: [UnsafeMutablePointer<CChar>?]) {
        for pointer in pointers {
            free(pointer)
        }
    }
}

private func collectProcessOutput(
    from descriptor: Int32,
    parentTerminated: LockedFlag,
    onChunk: (@Sendable (String) -> Void)?
) async -> ProcessRunner.CollectedOutput {
    defer { _ = Darwin.close(descriptor) }

    let readSize = 64 * 1024
    let maximumReadsAfterParentTermination = 16
    var readsAfterParentTermination = 0
    var buffer = [UInt8](repeating: 0, count: readSize)
    var collector = BoundedOutputCollector(
        maximumBytes: ProcessRunner.maximumRetainedOutputBytes,
        marker: ProcessRunner.outputTruncationMarker
    )
    // Multi-byte UTF-8 characters can straddle read() boundaries; hold back an
    // incomplete trailing sequence so streamed chunks never emit U+FFFD halves.
    var pendingStreamBytes = Data()

    while true {
        let parentHasTerminated = parentTerminated.value
        if parentHasTerminated,
           readsAfterParentTermination >= maximumReadsAfterParentTermination {
            break
        }

        var pollDescriptor = pollfd(
            fd: descriptor,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        )
        // Non-blocking poll: sleep cooperatively when idle so other tasks
        // (timeouts, cancellation, sibling process waits) can run.
        let pollResult = Darwin.poll(&pollDescriptor, 1, 0)
        if pollResult == 0 {
            if parentHasTerminated {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
            continue
        }
        if pollResult < 0 {
            if errno == EINTR {
                continue
            }
            break
        }

        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        if count > 0 {
            let chunk = Data(buffer.prefix(count))
            collector.append(chunk)
            if let onChunk {
                pendingStreamBytes.append(chunk)
                let holdback = ProcessRunner.incompleteUTF8SuffixLength(of: pendingStreamBytes)
                let decodableCount = pendingStreamBytes.count - holdback
                if decodableCount > 0 {
                    onChunk(String(decoding: pendingStreamBytes.prefix(decodableCount), as: UTF8.self))
                    // Copy to re-base indices and release the full read buffer.
                    pendingStreamBytes = Data(pendingStreamBytes.suffix(holdback))
                }
            }
            if parentHasTerminated {
                readsAfterParentTermination += 1
            }
            continue
        }
        if count == 0 {
            break
        }
        if errno == EINTR {
            continue
        }
        break
    }

    // Flush any bytes still held back (incomplete sequence at EOF decodes as U+FFFD).
    if let onChunk, !pendingStreamBytes.isEmpty {
        onChunk(String(decoding: pendingStreamBytes, as: UTF8.self))
    }

    return collector.result()
}

private struct BoundedOutputCollector {
    private let maximumBytes: Int
    private let marker: Data
    private let headCapacity: Int
    private let tailCapacity: Int
    private var totalBytes = 0
    private var head = Data()
    private var tailChunks: [Data] = []
    private var tailByteCount = 0

    init(maximumBytes: Int, marker: String) {
        self.maximumBytes = max(0, maximumBytes)
        self.marker = Data(marker.utf8)
        headCapacity = maximumBytes / 2
        tailCapacity = maximumBytes - headCapacity
    }

    mutating func append(_ chunk: Data) {
        if totalBytes <= Int.max - chunk.count {
            totalBytes += chunk.count
        } else {
            totalBytes = Int.max
        }

        var remainder = chunk
        if head.count < headCapacity {
            let accepted = min(headCapacity - head.count, remainder.count)
            head.append(remainder.prefix(accepted))
            remainder.removeFirst(accepted)
        }
        appendToTail(remainder)
    }

    func result() -> ProcessRunner.CollectedOutput {
        var retained = head
        let truncated = totalBytes > maximumBytes
        if truncated {
            retained.append(marker)
        }
        for chunk in tailChunks {
            retained.append(chunk)
        }
        return ProcessRunner.CollectedOutput(
            text: String(decoding: retained, as: UTF8.self),
            truncated: truncated
        )
    }

    private mutating func appendToTail(_ chunk: Data) {
        guard tailCapacity > 0, !chunk.isEmpty else { return }
        if chunk.count >= tailCapacity {
            tailChunks = [Data(chunk.suffix(tailCapacity))]
            tailByteCount = tailCapacity
            return
        }

        tailChunks.append(chunk)
        tailByteCount += chunk.count
        var overflow = tailByteCount - tailCapacity
        while overflow > 0, !tailChunks.isEmpty {
            if tailChunks[0].count <= overflow {
                let removed = tailChunks.removeFirst()
                overflow -= removed.count
                tailByteCount -= removed.count
            } else {
                tailChunks[0].removeFirst(overflow)
                tailByteCount -= overflow
                overflow = 0
            }
        }
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

private final class SpawnCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var processIdentifier: pid_t?
    private var isCancelled = false

    /// Registers a child that is still suspended and returns whether
    /// cancellation arrived before registration completed.
    func register(_ processIdentifier: pid_t) -> Bool {
        lock.lock()
        self.processIdentifier = processIdentifier
        let cancelled = isCancelled
        lock.unlock()
        return cancelled
    }

    /// Marks launch cancellation and returns the suspended/unmonitored child,
    /// when one has already been registered.
    func cancel() -> pid_t? {
        lock.lock()
        isCancelled = true
        let processIdentifier = processIdentifier
        lock.unlock()
        return processIdentifier
    }

    func clear(_ processIdentifier: pid_t) {
        lock.lock()
        if self.processIdentifier == processIdentifier {
            self.processIdentifier = nil
        }
        lock.unlock()
    }
}
