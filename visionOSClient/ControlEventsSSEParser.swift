import Foundation

struct ControlEventsSSEFrame: Equatable {
    let event: String
    let data: String
    let id: String
    let retryMilliseconds: UInt64?
}

/// Parses bytes, not URLSession lines, so CR, CRLF and split UTF-8 have one boundary.
struct ControlEventsSSEParser {
    enum Failure: Error, Equatable { case oversizedFrame, invalidUTF8, interruptedFrame }
    let maximumFrameBytes: Int
    private var line = [UInt8]()
    private var data = [String]()
    private var event = ""
    private var lastID = ""
    private var retry: UInt64?
    private var frameBytes = 0
    private var firstLine = true
    private var skipLF = false

    init(maximumFrameBytes: Int = 33_554_432) {
        self.maximumFrameBytes = max(1, maximumFrameBytes)
    }

    mutating func append(_ bytes: Data) throws -> [ControlEventsSSEFrame] {
        var frames = [ControlEventsSSEFrame]()
        for byte in bytes { if let frame = try append(byte) { frames.append(frame) } }
        return frames
    }

    mutating func append(_ byte: UInt8) throws -> ControlEventsSSEFrame? {
        if skipLF {
            skipLF = false
            if byte == 10 { return nil }
        }
        frameBytes += 1
        guard frameBytes <= maximumFrameBytes else { throw Failure.oversizedFrame }
        if byte == 10 || byte == 13 {
            let frame = try consumeLine()
            skipLF = byte == 13
            return frame
        }
        line.append(byte)
        return nil
    }

    func finish() throws {
        guard line.isEmpty && data.isEmpty && event.isEmpty else { throw Failure.interruptedFrame }
    }

    private mutating func consumeLine() throws -> ControlEventsSSEFrame? {
        if firstLine {
            firstLine = false
            if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
        }
        guard let text = String(bytes: line, encoding: .utf8) else { throw Failure.invalidUTF8 }
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            let frame = data.isEmpty ? nil : ControlEventsSSEFrame(
                event: event.isEmpty ? "message" : event, data: data.joined(separator: "\n"),
                id: lastID, retryMilliseconds: retry)
            data.removeAll(keepingCapacity: true)
            event = ""
            frameBytes = 0
            return frame
        }
        if text.first == ":" { return nil }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.first == " " { value.removeFirst() }
        switch field {
        case "data": data.append(value)
        case "event": event = value
        case "id": if !value.contains("\0") { lastID = value }
        case "retry":
            if !value.isEmpty && value.utf8.allSatisfy({ (48...57).contains($0) }), let number = UInt64(value) {
                retry = number
            }
        default: break // SSE extension fields do not define application state.
        }
        return nil
    }
}
