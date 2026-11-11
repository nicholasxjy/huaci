import Foundation

/// Framing shared by the buffered provider streams; each event joins its data lines.
enum ServerSentEvents {
    static func payloads(from data: Data) -> [String] {
        let stream = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var events: [String] = []
        var lines: [String] = []
        for line in stream.components(separatedBy: "\n").dropLast() {
            if line.isEmpty {
                if !lines.isEmpty { events.append(lines.joined(separator: "\n")) }
                lines.removeAll(keepingCapacity: true)
            } else if line == "data" {
                lines.append("")
            } else if line.hasPrefix("data:") {
                var value = line.dropFirst(5)
                if value.first == " " { value = value.dropFirst() }
                lines.append(String(value))
            }
        }
        // SSE dispatches only at an empty line; an unfinished frame is discarded.
        return events
    }
}
