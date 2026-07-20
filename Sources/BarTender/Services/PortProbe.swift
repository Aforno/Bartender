import Foundation
import Network

enum PortProbe {
    static func isOpen(host: String, port: Int, timeout: TimeInterval = 2) async -> Bool {
        guard (1...65535).contains(port), timeout > 0,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)

        return await withCheckedContinuation { continuation in
            let state = FinishState()

            connection.stateUpdateHandler = { connectionState in
                switch connectionState {
                case .ready:
                    state.finish(true, connection: connection, continuation: continuation)
                case .failed, .cancelled:
                    state.finish(false, connection: connection, continuation: continuation)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                state.finish(false, connection: connection, continuation: continuation)
            }
        }
    }
}

private final class FinishState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func finish(
        _ value: Bool,
        connection: NWConnection,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        connection.cancel()
        continuation.resume(returning: value)
    }
}
