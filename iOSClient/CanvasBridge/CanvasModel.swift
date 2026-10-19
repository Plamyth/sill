import Foundation
import CryptoKit
import Darwin
import CoreGraphics

struct CanvasPoint: Codable, Equatable {
    var x: Double
    var y: Double
}

struct CanvasViewport: Equatable {
    var zoom = 1.0
    var pan = CGSize.zero

    func translated(by shift: CGSize) -> CanvasViewport {
        CanvasViewport(zoom: zoom,
                       pan: CGSize(width: pan.width + shift.width, height: pan.height + shift.height))
    }

    func scaled(by factor: Double, around anchor: CGPoint, centerShift: CGSize) -> CanvasViewport {
        guard factor.isFinite, factor > 0 else { return self }
        let nextZoom = min(3, max(0.5, zoom * factor))
        let difference = CGFloat(zoom - nextZoom)
        return CanvasViewport(zoom: nextZoom,
                              pan: CGSize(width: pan.width + difference * anchor.x + centerShift.width,
                                          height: pan.height + difference * anchor.y + centerShift.height))
    }
}

struct CanvasRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var center: CanvasPoint { CanvasPoint(x: x + width / 2, y: y + height / 2) }
}

struct InkPoint: Codable, Equatable {
    var x: Double
    var y: Double
    var pressure: Double
}

struct InkStroke: Codable, Identifiable, Equatable {
    struct Visibility: Codable, Equatable {
        enum Kind: String, Codable { case full, masked }
        struct Segment: Codable, Equatable {
            var lowerBound: Double
            var upperBound: Double
            var worldPoints: [InkPoint]
        }
        var kind: Kind
        var visibleSegments: [Segment] = []
    }

    var id: UUID
    var points: [InkPoint]
    var createdAt: Date
    var visibility: Visibility? = nil

    // Legacy points are a best-effort fallback; nil visibility still means unknown.
    var visiblePointSegments: [[InkPoint]] {
        switch visibility?.kind {
        case .full: return [points]
        case .masked: return visibility?.visibleSegments.map(\.worldPoints) ?? []
        case nil: return [points]
        }
    }
}

struct VaultNoteReference: Codable, Equatable {
    enum SourceState: String, Codable { case current, changed, missing, ambiguous, unsupported, unavailable }
    let path: String
    var sha256: String
    let relayAddress: String
    var cacheTruncated: Bool? = nil
    var blockID: String? = nil
    var sourceState: SourceState? = nil
    var observedSha256: String? = nil
    var quoteSha256: String? = nil

    var sourceStateLabel: String {
        switch sourceState {
        case .current: return "원본 확인됨 · 표시 텍스트는 캐시입니다."
        case .changed: return "원본 변경됨 · 최신 표시 캐시입니다."
        case .missing: return "출처 없음 · 마지막 확인 발췌를 유지합니다."
        case .ambiguous: return "블록 ID 중복 · 마지막 확인 발췌를 유지합니다."
        case .unsupported: return "지원하지 않는 블록 · 마지막 확인 발췌를 유지합니다."
        case .unavailable, nil: return "원본 확인 필요 · 저장된 표시 캐시입니다."
        }
    }

    static func validPath(_ path: String) -> Bool {
        !path.isEmpty && path.count <= 1024 && path.hasSuffix(".md") &&
        !path.contains("\\") && !path.contains("\0") &&
        path.split(separator:"/",omittingEmptySubsequences:false).allSatisfy {
            !$0.isEmpty && !$0.hasPrefix(".")
        }
    }
}

enum VaultBlockError: LocalizedError {
    case unsupported, ambiguous, missing, selection

    var errorDescription: String? {
        switch self {
        case .unsupported: return "일반 문단만 발췌할 수 있습니다. 복합 블록이나 분리된 표식은 지원하지 않습니다."
        case .ambiguous: return "같은 블록 ID가 여러 곳에 있어 출처를 확정할 수 없습니다."
        case .missing: return "원본에서 블록 표식을 찾지 못했습니다. 저장된 발췌는 유지합니다."
        case .selection: return "한 문단 안을 누르거나 해당 문단의 텍스트를 선택하세요."
        }
    }
}

struct VaultExcerptBlock: Equatable {
    let byteRange: Range<Int>
    let utf16Range: NSRange
    let quote: String
    let blockID: String?

    func selection(in text: String) -> NSRange? {
        guard Range(utf16Range,in:text) != nil else { return nil }
        return utf16Range
    }
}

struct VaultMarkdownBlocks {
    private struct Line {
        let range: Range<Int>
        let utf16Range: NSRange
        let text: String
        let excluded: Bool
        var blank: Bool { text.trimmingCharacters(in:.whitespaces).isEmpty }
    }
    let text: String
    private let blocks: [VaultExcerptBlock]
    private let markers: [String:Int]

    init(_ text: String) {
        self.text = text
        let bytes = Array(text.utf8)
        var lines: [Line] = []
        var start = 0
        var utf16Offset = 0
        var fence: (UInt8, Int)?
        var frontmatter = false
        let opaqueDocument = text.contains("<") || text.contains("%%") || text.contains("$$")
        while start < bytes.count {
            let end = bytes[start...].firstIndex(of:10) ?? bytes.count
            let contentEnd = end > start && bytes[end - 1] == 13 ? end - 1 : end
            let line = String(decoding:bytes[start..<contentEnd],as:UTF8.self)
            let trimmed = line.trimmingCharacters(in:.whitespaces)
            var excluded = opaqueDocument || frontmatter || fence != nil
            if start == 0 && (trimmed == "---" || trimmed == "\u{feff}---") {
                frontmatter = true
                excluded = true
            } else if frontmatter && (trimmed == "---" || trimmed == "...") {
                frontmatter = false
            } else if !frontmatter, let first = trimmed.utf8.first, first == 96 || first == 126 {
                let count = trimmed.utf8.prefix(while:{ $0 == first }).count
                if count >= 3 {
                    excluded = true
                    if let open = fence {
                        if open.0 == first && count >= open.1 && trimmed.utf8.count == count { fence = nil }
                    } else { fence = (first,count) }
                }
            }
            lines.append(Line(range:start..<contentEnd,utf16Range:NSRange(location:utf16Offset,length:line.utf16.count),
                              text:line,excluded:excluded))
            utf16Offset += line.utf16.count + (end - contentEnd) + (end < bytes.count ? 1 : 0)
            start = end + 1
        }
        let marker = try! NSRegularExpression(pattern:"(?:^|[ \\t])\\^([A-Za-z0-9-]+)(?=[ \\t]*\\r?$)",
                                               options:.anchorsMatchLines)
        let ns = text as NSString
        var counts: [String:Int] = [:]
        for match in marker.matches(in:text,range:NSRange(location:0,length:ns.length)) {
            counts[ns.substring(with:match.range(at:1)),default:0] += 1
        }
        markers = counts
        let structural = try! NSRegularExpression(pattern:"^(?:[ #>+*\\-_=~`!\\[\\\\:]|[0-9]+[.)](?:[ \\t]|$))")
        var parsed: [VaultExcerptBlock] = []
        var cursor = 0
        while cursor < lines.count {
            if lines[cursor].blank { cursor += 1; continue }
            let lower = cursor
            while cursor < lines.count && !lines[cursor].blank { cursor += 1 }
            let chunk = Array(lines[lower..<cursor])
            guard !chunk.contains(where: { $0.excluded }), let first = chunk.first, let last = chunk.last else { continue }
            var quoteEnd = last.range.upperBound
            var id: String?
            let lastText = last.text as NSString
            if let match = marker.firstMatch(in:last.text,range:NSRange(location:0,length:lastText.length)),
               match.range.location > 0 {
                id = lastText.substring(with:match.range(at:1))
                quoteEnd = last.range.lowerBound + lastText.substring(to:match.range.location).utf8.count
            }
            let quote = String(decoding:bytes[first.range.lowerBound..<quoteEnd],as:UTF8.self)
            let plainLines = quote.components(separatedBy:"\n")
            guard plainLines.allSatisfy({ raw in
                let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
                return !line.isEmpty && !line.hasPrefix("\u{feff}") && !line.hasSuffix(" ") && !line.hasSuffix("\t") &&
                    !line.contains(where:{ "\t\r^`|<>[\\".contains($0) }) &&
                    structural.firstMatch(in:line,range:NSRange(location:0,length:(line as NSString).length)) == nil
            }) else { continue }
            var following = cursor
            while following < lines.count && lines[following].blank { following += 1 }
            if following < lines.count && lines[following].text.hasPrefix("^") { continue }
            parsed.append(VaultExcerptBlock(byteRange:first.range.lowerBound..<last.range.upperBound,
                                            utf16Range:NSRange(location:first.utf16Range.location,
                                                length:NSMaxRange(last.utf16Range) - first.utf16Range.location),
                                            quote:quote,blockID:id))
        }
        blocks = parsed
    }

    func selected(_ selection: NSRange) throws -> VaultExcerptBlock {
        guard selection.location >= 0, selection.length >= 0,
              selection.location <= text.utf16.count, selection.length <= text.utf16.count - selection.location,
              Range(selection,in:text) != nil else { throw VaultBlockError.selection }
        guard let block = blocks.first(where:{ block in
            let range = block.utf16Range
            return selection.location >= range.location && selection.location <= NSMaxRange(range) &&
                NSMaxRange(selection) <= NSMaxRange(range)
        }) else { throw VaultBlockError.unsupported }
        if let id = block.blockID, markers[id] != 1 { throw VaultBlockError.ambiguous }
        return block
    }

    func resolve(_ id: String) throws -> VaultExcerptBlock {
        guard markers[id,default:0] > 0 else { throw VaultBlockError.missing }
        guard markers[id] == 1 else { throw VaultBlockError.ambiguous }
        guard let block = blocks.first(where:{ $0.blockID == id }) else { throw VaultBlockError.unsupported }
        return block
    }

    func anchored(_ block: VaultExcerptBlock) throws -> (text: String, blockID: String) {
        guard blocks.contains(block) else { throw VaultBlockError.selection }
        if let id = block.blockID { _ = try resolve(id); return (text,id) }
        let id = "sill-" + UUID().uuidString.lowercased()
        let bytes = Array(text.utf8)
        let insertion = Array(" ^\(id)".utf8)
        guard bytes.count + insertion.count <= 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        return (String(decoding:bytes[..<block.byteRange.upperBound] + insertion + bytes[block.byteRange.upperBound...],
                       as:UTF8.self),id)
    }
}

struct VaultNoteSnapshot: Decodable, Equatable {
    let path: String
    let text: String
    let sha256: String
    let modifiedAt: String

    var preview: String {
        Self.preview(text)
    }

    static func preview(_ text: String) -> String {
        var bytes = Data(text.utf8.prefix(512))
        while !bytes.isEmpty {
            if let text = String(data:bytes,encoding:.utf8) { return text }
            bytes.removeLast()
        }
        return ""
    }

    func validated(at expected: String) throws -> Self {
        guard path == expected, VaultNoteReference.validPath(path),
              text.utf8.count <= 1024 * 1024,
              CanvasPacket.sha(Data(text.utf8)) == sha256 else {
            throw URLError(.badServerResponse)
        }
        return self
    }
}

struct CanvasNode: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case note, box }
    enum Confidence: String, Codable { case confirmed, proposal }

    var id: UUID
    var kind: Kind
    var frame: CanvasRect
    var text: String
    var confidence: Confidence
    var sourceStrokeIds: [UUID]
    var vaultNote: VaultNoteReference? = nil
}

struct CanvasLink: Codable, Identifiable, Equatable {
    var id: UUID
    var from: UUID
    var to: UUID
    var label: String
}

struct CanvasAnnotation: Codable, Identifiable, Equatable {
    var id: UUID
    var nodeId: UUID?
    var text: String
    var author: String
}

struct CanvasScene: Codable, Equatable {
    var schemaVersion = 1
    var id = UUID()
    var revision = 0
    var width: Double = 2048
    var height: Double = 1536
    var drawingBase64 = ""
    var strokes: [InkStroke] = []
    var nodes: [CanvasNode] = []
    var links: [CanvasLink] = []
    var annotations: [CanvasAnnotation] = []

    mutating func addNode(kind: CanvasNode.Kind, at point: CanvasPoint, text: String = "",
                          confidence: CanvasNode.Confidence = .confirmed,
                          sourceStrokeIds: [UUID] = []) -> UUID {
        let id = UUID()
        nodes.append(CanvasNode(id: id, kind: kind,
            frame: CanvasRect(x: point.x, y: point.y, width: 260, height: 120),
            text: text, confidence: confidence, sourceStrokeIds: sourceStrokeIds))
        revision += 1
        return id
    }

    mutating func moveNode(_ id: UUID, to point: CanvasPoint) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[index].frame.x = point.x
        nodes[index].frame.y = point.y
        revision += 1
    }

    mutating func connect(_ from: UUID, to: UUID, label: String = "") -> Bool {
        guard from != to, nodes.contains(where: { $0.id == from }),
              nodes.contains(where: { $0.id == to }) else { return false }
        links.append(CanvasLink(id: UUID(), from: from, to: to, label: label))
        revision += 1
        return true
    }

    mutating func confirmNode(_ id: UUID, text: String) -> Bool {
        guard let index = nodes.firstIndex(where: { $0.id == id }),
              nodes[index].vaultNote == nil else { return false }
        nodes[index].text = text
        nodes[index].confidence = .confirmed
        revision += 1
        return true
    }

    mutating func apply(_ change: AgentRevision, basedOn sent: CanvasScene? = nil) -> Bool {
        guard change.sceneId == id else { return false }
        let annotationIds = change.annotations.map(\.id)
        let proposalIds = change.proposedNodes.map(\.id)
        let proposedLinks = change.proposedLinks ?? []
        let linkIds = proposedLinks.map(\.id)
        guard Set(annotationIds).count == annotationIds.count,
              Set(proposalIds).count == proposalIds.count,
              Set(linkIds).count == linkIds.count else { return false }
        if change.baseRevision < revision {
            guard !annotationIds.isEmpty || !proposalIds.isEmpty || !linkIds.isEmpty else { return false }
            if change.annotations.allSatisfy({ incoming in
                annotations.first(where: { $0.id == incoming.id }) == incoming
            }) && change.proposedNodes.allSatisfy({ incoming in
                nodes.first(where: { $0.id == incoming.id }) == incoming
            }) && proposedLinks.allSatisfy({ incoming in
                links.first(where: { $0.id == incoming.id }) == incoming
            }) { return true }
            guard let sent, sent.id == id, sent.revision == change.baseRevision,
                  sent.schemaVersion == schemaVersion,
                  sent.width == width, sent.height == height,
                  sent.nodes == nodes, sent.links == links, sent.annotations == annotations,
                  strokes.count > sent.strokes.count,
                  Array(strokes.prefix(sent.strokes.count)) == sent.strokes else {
                return false
            }
        }
        guard change.baseRevision <= revision else { return false }
        let existingIds = Set(nodes.map(\.id))
        let existingAnnotationIds = Set(annotations.map(\.id))
        let existingLinkIds = Set(links.map(\.id))
        let originalStrokes = change.baseRevision == revision ? strokes : sent?.strokes ?? []
        let sentStrokeIds = Set(originalStrokes.map(\.id))
        guard change.annotations.allSatisfy({ !existingAnnotationIds.contains($0.id) }),
              proposedLinks.allSatisfy({ !existingLinkIds.contains($0.id) }),
              change.proposedNodes.allSatisfy({ $0.vaultNote == nil && $0.confidence == .proposal && !existingIds.contains($0.id) &&
                  $0.sourceStrokeIds.allSatisfy(sentStrokeIds.contains) }) else {
            return false
        }
        let availableIds = existingIds.union(proposalIds)
        guard change.annotations.allSatisfy({ $0.nodeId.map(availableIds.contains) ?? true }),
              proposedLinks.allSatisfy({ $0.from != $0.to && availableIds.contains($0.from) &&
                  availableIds.contains($0.to) }) else {
            return false
        }
        annotations.append(contentsOf: change.annotations)
        nodes.append(contentsOf: change.proposedNodes)
        links.append(contentsOf: proposedLinks)
        revision += 1
        return true
    }
}

struct AgentRevision: Codable {
    var sceneId: UUID
    var baseRevision: Int
    var annotations: [CanvasAnnotation]
    var proposedNodes: [CanvasNode]
    var proposedLinks: [CanvasLink]? = nil
}

struct VoiceSession: Codable, Equatable {
    let threadId: UUID
    let sessionId: String
    let observedAt: String

    func samePair(as other: VoiceSession) -> Bool {
        threadId == other.threadId && sessionId == other.sessionId
    }
}

struct VoiceProjection: Codable {
    let generatedAt: String
    let activeVoiceSession: VoiceSession?

    func session(matching displayed: VoiceSession?, now: Date = Date()) throws -> VoiceSession {
        func recent(_ text: String) -> Bool {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
            let fractional = formatter.date(from:text)
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = fractional ?? formatter.date(from:text) else { return false }
            return now.timeIntervalSince(date) <= 30 && date.timeIntervalSince(now) <= 5
        }
        guard recent(generatedAt), let session = activeVoiceSession,
              !session.sessionId.isEmpty, recent(session.observedAt) else { throw CanvasSendError.unavailable }
        if let displayed, !displayed.samePair(as:session) { throw CanvasSendError.changedSession }
        return session
    }
}

enum CanvasSendError: LocalizedError {
    case unavailable, changedSession, missingTarget, invalidPacket, unresolvedPacket, receiptMismatch, outboxUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: return "현재 열린 음성 세션을 확인하지 못했습니다."
        case .changedSession: return "표시한 음성 대화 또는 세션이 바뀌었습니다. 다시 확인하세요."
        case .missingTarget: return "음성 대화가 없으면 받는 대화 카드를 먼저 선택하세요."
        case .invalidPacket: return "장면 1 MiB, PNG 5 MiB 한도 또는 패킷 바이트를 확인하세요."
        case .unresolvedPacket: return "이전 패킷의 접수 결과를 먼저 확인해야 합니다. 자동 재전송하지 않습니다."
        case .receiptMismatch: return "영수증의 패킷·대화·세션·해시가 일치하지 않습니다."
        case .outboxUnavailable: return "전송 원장을 읽거나 저장하지 못했습니다. 전송을 중단했습니다."
        }
    }
}

struct CanvasPacket: Codable, Equatable {
    let packetId: UUID
    let threadId: UUID
    let sessionId: String
    let targetMode: String?
    let imageSha256: String
    let sceneSha256: String
    let imagePNGBase64: String
    let sceneJSONBase64: String

    init(scene: CanvasScene, imagePNG: Data, session: VoiceSession, targetMode: String? = nil) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sceneBytes = try encoder.encode(scene)
        guard imagePNG.count <= 5*1024*1024, sceneBytes.count <= 1024*1024,
              imagePNG.starts(with:[137,80,78,71,13,10,26,10]), !session.sessionId.isEmpty else {
            throw CanvasSendError.invalidPacket
        }
        packetId = UUID()
        threadId = session.threadId
        sessionId = session.sessionId
        self.targetMode = targetMode
        imageSha256 = Self.sha(imagePNG)
        sceneSha256 = Self.sha(sceneBytes)
        imagePNGBase64 = imagePNG.base64EncodedString()
        sceneJSONBase64 = sceneBytes.base64EncodedString()
    }

    static func sha(_ bytes: Data) -> String {
        SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
    }

    func frozenScene() throws -> CanvasScene {
        guard let image = Data(base64Encoded:imagePNGBase64), image.count <= 5*1024*1024,
              let bytes = Data(base64Encoded:sceneJSONBase64), bytes.count <= 1024*1024,
              Self.sha(image) == imageSha256, Self.sha(bytes) == sceneSha256 else {
            throw CanvasSendError.invalidPacket
        }
        return try JSONDecoder().decode(CanvasScene.self,from:bytes)
    }
}

enum PacketState: String, Codable {
    case stored, dispatching, queued, steered, started, unknown, rejected
    var terminal: Bool { self == .queued || self == .steered || self == .started || self == .rejected }
}

struct PacketReceipt: Codable {
    struct Continuity: Codable {
        let status: String
        let atomic: Bool
        let before: VoiceSession?
        let after: VoiceSession?
    }
    let packetId: UUID
    let threadId: UUID
    let sessionId: String
    let targetMode: String?
    let state: PacketState
    let imageSha256: String
    let sceneSha256: String
    let queuedId: UUID?
    let turnId: UUID?
    let canonicalPacketId: UUID?
    let clientUserMessageId: UUID
    let deliveryScope: String
    let sessionContinuity: Continuity
    let reason: String?

    func matches(_ packet: CanvasPacket) -> Bool {
        packetId == packet.packetId && threadId == packet.threadId && sessionId == packet.sessionId &&
        targetMode == packet.targetMode &&
        imageSha256 == packet.imageSha256 && sceneSha256 == packet.sceneSha256 &&
        clientUserMessageId == (canonicalPacketId ?? packet.packetId) &&
        ["exact-chat-queue-only", "active-turn-steer", "exact-chat-start"].contains(deliveryScope) &&
        !sessionContinuity.atomic &&
        (state != .queued || (deliveryScope == "exact-chat-queue-only" && queuedId != nil)) &&
        (state != .steered || (deliveryScope == "active-turn-steer" && turnId != nil)) &&
        (state != .started || (deliveryScope == "exact-chat-start" && turnId != nil))
    }
}

struct CanvasOutboxEntry: Codable, Identifiable {
    enum Phase: String, Codable { case prepared, submitting, reconciling, settled }
    var id: UUID { packet.packetId }
    let packet: CanvasPacket
    let relayAddress: String
    var phase: Phase = .prepared
    var receipt: PacketReceipt?
}

struct CanvasOutbox: Codable {
    private(set) var entries: [CanvasOutboxEntry] = []
    var unresolved: CanvasOutboxEntry? { entries.first { $0.phase != .settled } }

    func existing(for scene: CanvasScene, threadId: UUID, sessionId: String) throws -> CanvasOutboxEntry? {
        if let unresolved { return unresolved }
        return try entries.last { entry in
            let frozen = try entry.packet.frozenScene()
            return frozen == scene &&
                entry.packet.threadId == threadId && entry.packet.sessionId == sessionId &&
                entry.receipt?.state != .rejected
        }
    }

    mutating func reserve(_ packet: CanvasPacket, relayAddress: String) throws {
        let scene = try packet.frozenScene()
        guard try existing(for:scene,threadId:packet.threadId,sessionId:packet.sessionId) == nil else { throw CanvasSendError.unresolvedPacket }
        entries.append(CanvasOutboxEntry(packet:packet,relayAddress:relayAddress))
    }

    mutating func beginSubmission(_ id: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].phase == .prepared else {
            throw CanvasSendError.unresolvedPacket
        }
        entries[index].phase = .submitting
    }

    mutating func accept(_ receipt: PacketReceipt) throws {
        guard let index = entries.firstIndex(where: { $0.id == receipt.packetId }),
              receipt.matches(entries[index].packet) else { throw CanvasSendError.receiptMismatch }
        if entries[index].receipt?.state.terminal == true { return }
        entries[index].receipt = receipt
        entries[index].phase = receipt.state.terminal ? .settled : .reconciling
    }

    func validate() throws {
        guard Set(entries.map(\.id)).count == entries.count,
              entries.filter({ $0.phase != .settled }).count <= 1 else { throw CanvasSendError.outboxUnavailable }
        for entry in entries {
            _ = try entry.packet.frozenScene()
            if let receipt = entry.receipt, !receipt.matches(entry.packet) { throw CanvasSendError.receiptMismatch }
            if entry.phase == .settled && entry.receipt?.state.terminal != true {
                throw CanvasSendError.outboxUnavailable
            }
        }
    }
}

enum CanvasLocalFile {
    private static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path,O_RDONLY)
        guard fd >= 0 else { throw CanvasSendError.outboxUnavailable }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw CanvasSendError.outboxUnavailable }
    }

    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,
                                                attributes:[.posixPermissions:0o700])
        try syncDirectory(directory.deletingLastPathComponent())
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temporary.path,O_WRONLY | O_CREAT | O_EXCL,0o600)
        guard fd >= 0 else { throw CanvasSendError.outboxUnavailable }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at:temporary) }
        try handle.write(contentsOf:data)
        try handle.synchronize()
        guard rename(temporary.path,url.path) == 0 else { throw CanvasSendError.outboxUnavailable }
        try syncDirectory(directory)
    }
}
