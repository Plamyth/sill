import Foundation

struct VaultPDFViewState: Codable, Equatable {
    struct Crop: Codable, Equatable {
        var x: Double = 0
        var y: Double = 0
        var width: Double = 1
        var height: Double = 1
        var valid: Bool {
            [x,y,width,height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0 &&
                x + width <= 1 && y + height <= 1
        }
    }
    let pdfPath: String
    let pdfSHA256: String
    let pageCount: Int
    var displayOrder: [Int]
    var crops: [Crop]
    static let marker = "<!-- ccr:pdf-view-state:v1 -->"
    private static let tableHeader = "| 원문 쪽 | x | y | width | height |"
    private static let tableDivider = "| --- | --- | --- | --- | --- |"

    init(snapshot: VaultPDFSnapshot, pageCount: Int) {
        pdfPath = snapshot.path; pdfSHA256 = snapshot.sha256; self.pageCount = pageCount
        displayOrder = pageCount > 0 ? Array(1...pageCount) : []; crops = Array(repeating:Crop(),count:max(0,pageCount))
    }

    var notePath: String {
        let parent = pdfPath.split(separator:"/").dropLast().joined(separator:"/")
        return (parent.isEmpty ? "" : parent + "/") + "PDF보기-\(pdfSHA256)-\(CanvasPacket.sha(Data(pdfPath.utf8))).md"
    }

    func validated(snapshot: VaultPDFSnapshot, pageCount count: Int) throws -> Self {
        guard pdfPath.utf8.elementsEqual(snapshot.path.utf8), pdfSHA256 == snapshot.sha256,
              VaultPDFSnapshot.validPath(pdfPath), pdfSHA256.count == 64,
              pdfSHA256.allSatisfy({ "0123456789abcdef".contains($0) }), pageCount > 0, pageCount == count,
              displayOrder.count == count, displayOrder.sorted() == Array(1...count),
              crops.count == count, crops.allSatisfy(\.valid) else { throw ViewError.invalid }
        return self
    }

    func markdown() throws -> String {
        _ = try validated(snapshot:.init(path:pdfPath,sha256:pdfSHA256,dataBase64:""),pageCount:pageCount)
        var lines = [Self.marker,"# PDF 보기 설정","","PDF 경로: \(pdfPath)","PDF SHA256: \(pdfSHA256)",
                     "물리 페이지 수: \(pageCount)","표시 순서: \(displayOrder.map(String.init).joined(separator:", "))","",
                     Self.tableHeader,Self.tableDivider]
        for (index,crop) in crops.enumerated() {
            lines.append("| \(index + 1) | \(crop.x) | \(crop.y) | \(crop.width) | \(crop.height) |")
        }
        let text = lines.joined(separator:"\n") + "\n"
        guard text.utf8.count <= 1024 * 1024 else { throw ViewError.invalid }
        return text
    }

    static func parse(_ text: String, snapshot: VaultPDFSnapshot, pageCount: Int) throws -> Self {
        guard text.utf8.count <= 1024 * 1024, pageCount > 0, pageCount <= text.utf8.count else { throw ViewError.invalid }
        var lines = text.replacingOccurrences(of:"\r\n",with:"\n").components(separatedBy:"\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.count == 10 + pageCount, lines[0] == marker, lines[1] == "# PDF 보기 설정",
              lines[2].isEmpty, lines[7].isEmpty,
              lines[8] == tableHeader, lines[9] == tableDivider else { throw ViewError.invalid }
        func field(_ index: Int, _ prefix: String) throws -> String {
            guard lines[index].hasPrefix(prefix) else { throw ViewError.invalid }
            return String(lines[index].dropFirst(prefix.count))
        }
        var state = Self(snapshot:snapshot,pageCount:pageCount)
        guard try field(3,"PDF 경로: ").utf8.elementsEqual(snapshot.path.utf8),
              try field(4,"PDF SHA256: ") == snapshot.sha256,
              try field(5,"물리 페이지 수: ") == String(pageCount) else { throw ViewError.invalid }
        let order = try field(6,"표시 순서: ").components(separatedBy:",").map { Int($0.trimmingCharacters(in:.whitespaces)) }
        guard order.allSatisfy({ $0 != nil }) else { throw ViewError.invalid }
        state.displayOrder = order.compactMap { $0 }
        state.crops = try lines.dropFirst(10).enumerated().map { index,line in
            let cells = line.components(separatedBy:"|").map { $0.trimmingCharacters(in:.whitespaces) }
            guard cells.count == 7, cells.first == "", cells.last == "", cells[1] == String(index + 1),
                  let x = Double(cells[2]), let y = Double(cells[3]), let width = Double(cells[4]), let height = Double(cells[5]) else { throw ViewError.invalid }
            return Crop(x:x,y:y,width:width,height:height)
        }
        return try state.validated(snapshot:snapshot,pageCount:pageCount)
    }

    enum ViewError: LocalizedError {
        case invalid, unconfirmed
        var errorDescription: String? {
            switch self {
            case .invalid: return "PDF 보기 설정의 원본·순서·자르기 형식을 확인하지 못했습니다. 현재 보기와 원본을 보존합니다."
            case .unconfirmed: return "보기 설정의 저장·재조회가 같은 원문인지 확인하지 못했습니다. 기존 저장 의도와 입력을 보존하세요."
            }
        }
    }

    struct SaveRequest: Codable, Equatable {
        let state: VaultPDFViewState
        let baseSHA256: String?
        let markdown: String
        var path: String { state.notePath }

        init(state: VaultPDFViewState, base: VaultNoteSnapshot?) throws {
            self.state = state; markdown = try state.markdown()
            if let base {
                _ = try base.validated(at:state.notePath)
                try Self.checkHeld(base)
                _ = try VaultPDFViewState.parse(base.text,snapshot:.init(path:state.pdfPath,sha256:state.pdfSHA256,dataBase64:""),pageCount:state.pageCount)
            }
            baseSHA256 = base?.sha256
        }

        static func checkHeld(_ note: VaultNoteSnapshot) throws {
            if note.reconciliationRequired == true {
                throw NSError(domain:"CanvasRelay",code:409,userInfo:[VaultSaveConflict.errorKey:VaultSaveConflict.reconciliationRequired.rawValue])
            }
        }

        func confirmed(_ note: VaultNoteSnapshot) throws -> VaultNoteSnapshot {
            try validated()
            _ = try note.validated(at:path); try Self.checkHeld(note)
            guard note.text.utf8.elementsEqual(markdown.utf8), note.sha256 == CanvasPacket.sha(Data(markdown.utf8)) else { throw ViewError.unconfirmed }
            return note
        }

        @MainActor func submit(save: (String,String?,String) async throws -> VaultNoteSnapshot,
                               load: (String) async throws -> VaultNoteSnapshot) async throws -> VaultNoteSnapshot {
            try validated()
            _ = try confirmed(await save(path,baseSHA256,markdown))
            return try confirmed(await load(path))
        }

        private func validated() throws {
            guard markdown.utf8.elementsEqual(try state.markdown().utf8),
                  baseSHA256.map({ $0.count == 64 && $0.allSatisfy({ "0123456789abcdef".contains($0) }) }) ?? true else { throw ViewError.invalid }
        }
    }
}
