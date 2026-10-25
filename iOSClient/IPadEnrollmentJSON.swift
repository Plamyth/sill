import Foundation

enum IPadEnrollmentFailure: Error, CustomStringConvertible {
    case invalid, storage, stale, cancelled, unavailable
    case server(Int, String)
    var description: String { "iPad 기기 등록을 확인하지 못했습니다." }
}

/// 숫자의 원래 표기와 중복 키는 JSONDecoder가 지우기 전에 검사한다.
indirect enum IPadEnrollmentJSON: Equatable {
    case object([String: IPadEnrollmentJSON]), array([IPadEnrollmentJSON]), string(String)
    case number(String), bool(Bool), null

    static func integer(_ value: Int64) -> Self { .number(String(value)) }
    static func parse(_ data: Data, limit: Int = 4096) throws -> Self {
        guard !data.isEmpty, data.count <= limit, String(data: data, encoding: .utf8) != nil,
              !data.starts(with: [0xef, 0xbb, 0xbf]) else { throw IPadEnrollmentFailure.invalid }
        var parser = Parser(bytes: Array(data))
        let value = try parser.value(0)
        parser.space()
        guard parser.at == parser.bytes.count else { throw IPadEnrollmentFailure.invalid }
        return value
    }

    func fields(_ names: Set<String>) throws -> [String: Self] {
        guard case .object(let result) = self, Set(result.keys) == names else { throw IPadEnrollmentFailure.invalid }
        return result
    }
    func text() throws -> String {
        guard case .string(let value) = self else { throw IPadEnrollmentFailure.invalid }
        return value
    }
    func integer() throws -> Int64 {
        guard case .number(let raw) = self, !raw.isEmpty,
              raw.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int64(raw), value <= 9_007_199_254_740_991 else { throw IPadEnrollmentFailure.invalid }
        return value
    }
    func bytes() throws -> Data { Data(try canonical().utf8) }
    func canonical() throws -> String {
        switch self {
        case .object(let fields):
            return "{" + (try fields.keys.sorted().map { try Self.string($0).canonical() + ":" + fields[$0]!.canonical() }).joined(separator: ",") + "}"
        case .array(let values): return "[" + (try values.map { try $0.canonical() }).joined(separator: ",") + "]"
        case .string(let value):
            let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            guard let text = String(data: data, encoding: .utf8) else { throw IPadEnrollmentFailure.invalid }
            return text
        case .number(let raw): return raw
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var at = 0
        mutating func space() { while at < bytes.count && [9, 10, 13, 32].contains(bytes[at]) { at += 1 } }
        mutating func take(_ byte: UInt8) -> Bool {
            guard at < bytes.count, bytes[at] == byte else { return false }
            at += 1; return true
        }
        mutating func string() throws -> String {
            let start = at
            guard take(34) else { throw IPadEnrollmentFailure.invalid }
            while at < bytes.count {
                let byte = bytes[at]; at += 1
                if byte == 34 {
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start..<at]))
                }
                if byte == 92 { at += 1 }
            }
            throw IPadEnrollmentFailure.invalid
        }
        mutating func value(_ depth: Int) throws -> IPadEnrollmentJSON {
            space()
            guard depth <= 24, at < bytes.count else { throw IPadEnrollmentFailure.invalid }
            if bytes[at] == 34 { return .string(try string()) }
            if take(123) {
                var fields: [String: IPadEnrollmentJSON] = [:]
                space(); if take(125) { return .object(fields) }
                while true {
                    space(); let key = try string(); space()
                    guard fields[key] == nil, take(58) else { throw IPadEnrollmentFailure.invalid }
                    fields[key] = try value(depth + 1); space()
                    if take(125) { return .object(fields) }
                    guard take(44) else { throw IPadEnrollmentFailure.invalid }
                }
            }
            if take(91) {
                var values: [IPadEnrollmentJSON] = []
                space(); if take(93) { return .array(values) }
                while true {
                    values.append(try value(depth + 1)); space()
                    if take(93) { return .array(values) }
                    guard take(44) else { throw IPadEnrollmentFailure.invalid }
                }
            }
            let start = at
            while at < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[at]) { at += 1 }
            let token = String(decoding: bytes[start..<at], as: UTF8.self)
            switch token {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default:
                guard token.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else {
                    throw IPadEnrollmentFailure.invalid
                }
                return .number(token)
            }
        }
    }
}

extension Dictionary where Key == String, Value == IPadEnrollmentJSON {
    func text(_ key: String) throws -> String { guard let value = self[key] else { throw IPadEnrollmentFailure.invalid }; return try value.text() }
    func integer(_ key: String) throws -> Int64 { guard let value = self[key] else { throw IPadEnrollmentFailure.invalid }; return try value.integer() }
}
