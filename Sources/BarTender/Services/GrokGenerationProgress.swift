import Foundation

/// Converts Grok JSONL chunks into short progress updates, without exposing reasoning.
final class GrokGenerationProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private var discardingLine = false
    private var stage = 0

    func consume(_ chunk: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var messages: [String] = []
        for character in chunk {
            if character == "\n" {
                if !discardingLine, let message = progress(for: pending) {
                    messages.append(message)
                }
                pending.removeAll(keepingCapacity: true)
                discardingLine = false
            } else if !discardingLine {
                pending.append(character)
                if pending.utf8.count > 65_536 {
                    pending.removeAll(keepingCapacity: true)
                    discardingLine = true
                }
            }
        }
        return messages
    }

    /// Progress is monotonic even when the provider interleaves thinking and text.
    private func progress(for line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(Event.self, from: data) else { return nil }
        let next: Int
        switch event.type {
        case "system": next = 1
        case "stream_event":
            switch event.event?.delta?.type ?? event.event?.content_block?.type {
            case "thinking_delta", "thinking": next = 2
            case "text_delta", "text": next = 3
            default: return nil
            }
        case "assistant": next = 4
        case "result": next = 5
        default: return nil
        }
        guard next > stage else { return nil }
        stage = next
        return ["", "Grok is preparing the request…", "Grok is thinking…",
                "Grok is writing the tool…", "Grok is finishing the response…",
                "Checking Grok’s response…"][next]
    }

    private struct Event: Decodable {
        let type: String
        let event: PartialEvent?
    }

    private struct PartialEvent: Decodable {
        let delta: Block?
        let content_block: Block?
    }

    private struct Block: Decodable {
        let type: String
    }
}
