import SwiftUI
import PDFKit

private final class VaultReadOnlyPDFView: PDFView {
    var localGoTo: ((PDFDestination) -> Void)?
    override func perform(_ action: PDFAction) {
        if let goTo = action as? PDFActionGoTo {
            if goTo.destination.page?.document === document { super.perform(action) }
            else { localGoTo?(goTo.destination) }
        }
    }
}

@MainActor final class VaultPDFReader: NSObject, ObservableObject, PDFViewDelegate {
    let snapshot: VaultPDFSnapshot
    let view: PDFView
    private let document: PDFDocument
    private var displayedDocument: PDFDocument
    @Published private(set) var viewState: VaultPDFViewState
    @Published private(set) var sourceRevealed = false
    @Published private var savedViewState: VaultPDFViewState
    private var sidecarLoaded: Bool
    private var viewUndo = [VaultPDFViewState]()
    private var viewRedo = [VaultPDFViewState]()
    var hasViewEdits: Bool { viewState != savedViewState }
    var canUndoViewState: Bool { !viewUndo.isEmpty }
    var canRedoViewState: Bool { !viewRedo.isEmpty }
    var displayPageNumber: Int { (viewState.displayOrder.firstIndex(of:pageNumber) ?? 0) + 1 }
    struct OutlineEntry: Identifiable {
        let id: Int
        let title: String
        let depth: Int
        let pageNumber: Int?
        fileprivate let outline: PDFOutline
    }
    static let outlineDepthLimit = 8
    static let outlineEntryLimit = 256
    let outlineEntries: [OutlineEntry]
    let outlineTruncated: Bool
    private let outlineRoot: PDFOutline?
    @Published private(set) var pageIndex = 0
    var pageCount: Int { document.pageCount }
    var pageNumber: Int { pageIndex + 1 }
    var selectionPageNumber: Int? {
        guard let selection = view.currentSelection, selection.pages.count == 1,
              let page = selection.pages.first else { return nil }
        guard view.document === displayedDocument else { return nil }
        let index = displayedDocument.index(for:page)
        return viewState.displayOrder.indices.contains(index) ? viewState.displayOrder[index] : nil
    }

    init(snapshot: VaultPDFSnapshot, source: VaultPDFExcerpt? = nil, viewState initialState: VaultPDFViewState? = nil) throws {
        let bytes = try snapshot.bytes(at:snapshot.path)
        let opened: PDFDocument
        let anchor: (PDFPage,PDFSelection)?
        if let source {
            let (sourceDocument,page,selection) = try source.sourcePage(in:snapshot)
            opened = sourceDocument
            anchor = (page,selection)
        } else {
            guard let value = PDFDocument(data:bytes), !value.isLocked, value.pageCount > 0 else { throw VaultPDFError.invalid }
            opened = value
            anchor = nil
        }
        self.snapshot = snapshot
        document = opened
        displayedDocument = opened
        let state = try (initialState ?? VaultPDFViewState(snapshot:snapshot,pageCount:opened.pageCount)).validated(snapshot:snapshot,pageCount:opened.pageCount)
        viewState = state; savedViewState = state
        sidecarLoaded = initialState != nil
        outlineRoot = opened.outlineRoot
        (outlineEntries,outlineTruncated) = Self.readOutline(in:opened)
        view = VaultReadOnlyPDFView()
        super.init()
        (view as? VaultReadOnlyPDFView)?.localGoTo = { [weak self] destination in
            guard let self, let page = destination.page else { return }
            if page.document === self.document {
                let index = self.document.index(for:page)
                if index != NSNotFound { _ = self.go(toPageNumber:index + 1) }
            } else if page.document === self.displayedDocument {
                let index = self.displayedDocument.index(for:page)
                if self.viewState.displayOrder.indices.contains(index) { _ = self.go(toPageNumber:self.viewState.displayOrder[index]) }
            }
        }
        view.delegate = self
        view.isInMarkupMode = false
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = document
        NotificationCenter.default.addObserver(self,selector:#selector(pageChanged),name:.PDFViewPageChanged,object:view)
        NotificationCenter.default.addObserver(self,selector:#selector(selectionChanged),name:.PDFViewSelectionChanged,object:view)
        view.displayBox = .cropBox
        try install(state,physicalPage:source?.pageIndex ?? 0,selection:anchor?.1)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func pageChanged() {
        guard view.document === displayedDocument, let page = view.currentPage else { return }
        let index = displayedDocument.index(for:page)
        if viewState.displayOrder.indices.contains(index) { pageIndex = viewState.displayOrder[index] - 1 }
    }

    @objc private func selectionChanged() { objectWillChange.send() }

    @discardableResult
    func go(toPageNumber number: Int) -> Bool {
        guard number > 0, number <= pageCount, view.document === displayedDocument,
              let index = viewState.displayOrder.firstIndex(of:number) else { return false }
        if sourceRevealed {
            do { try install(viewState,physicalPage:number - 1,selection:nil) } catch { return false }
        }
        guard let page = displayedDocument.page(at:index) else { return false }
        view.clearSelection()
        view.go(to:page)
        pageChanged()
        return view.currentPage === page
    }

    @discardableResult func go(toDisplayPageNumber number: Int) -> Bool {
        guard number > 0, number <= pageCount else { return false }
        return go(toPageNumber:viewState.displayOrder[number - 1])
    }

    private func cropRect(_ state: VaultPDFViewState, physicalPage: Int) throws -> CGRect {
        guard let page = document.page(at:physicalPage) else { throw VaultPDFViewState.ViewError.invalid }
        let box = page.bounds(for:.cropBox), c = state.crops[physicalPage]
        let minX = box.minX + box.width * c.x, minY = box.minY + box.height * c.y
        let maxX = box.minX + box.width * (c.x + c.width), maxY = box.minY + box.height * (c.y + c.height)
        let rect = CGRect(x:minX,y:minY,width:maxX - minX,height:maxY - minY)
        guard VaultPDFExcerpt.Rect(rect).valid, box.contains(rect) else { throw VaultPDFViewState.ViewError.invalid }
        return rect
    }

    private func translate(_ selection: PDFSelection, from page: PDFPage, to target: PDFPage, in doc: PDFDocument) throws -> PDFSelection {
        guard selection.pages.count == 1, selection.pages.first === page else { throw VaultPDFError.selection }
        if page === target { return selection }
        let count = selection.numberOfTextRanges(on:page)
        guard count > 0, count <= 256 else { throw VaultPDFError.selection }
        let result = PDFSelection(document:doc)
        for i in 0..<count {
            let range = selection.range(at:i,on:page)
            guard VaultPDFExcerpt.TextRange(range).valid, let part = target.selection(for:range),
                  part.numberOfTextRanges(on:target) == 1, part.range(at:0,on:target) == range else { throw VaultPDFError.selection }
            result.add(part)
        }
        guard result.string?.utf8.elementsEqual((selection.string ?? "").utf8) == true else { throw VaultPDFError.selection }
        return result
    }

    private func originalSelection() throws -> PDFSelection? {
        guard view.document === displayedDocument else { throw VaultPDFError.changed }
        guard let selection = view.currentSelection else { return nil }
        guard selection.pages.count == 1, let page = selection.pages.first else { throw VaultPDFError.selection }
        let index = displayedDocument.index(for:page)
        guard viewState.displayOrder.indices.contains(index), let original = document.page(at:viewState.displayOrder[index] - 1) else { throw VaultPDFError.selection }
        return try translate(selection,from:page,to:original,in:document)
    }

    private func install(_ state: VaultPDFViewState, physicalPage: Int, selection: PDFSelection?) throws {
        _ = try state.validated(snapshot:snapshot,pageCount:pageCount)
        guard physicalPage >= 0, physicalPage < pageCount, let original = document.page(at:physicalPage),
              let index = state.displayOrder.firstIndex(of:physicalPage + 1) else { throw VaultPDFViewState.ViewError.invalid }
        let reveal = try selection.map { !(try cropRect(state,physicalPage:physicalPage)).contains($0.bounds(for:original)) } ?? false
        let identity = state.displayOrder == Array(1...pageCount) && state.crops.allSatisfy({ $0 == .init() })
        let display: PDFDocument
        if identity { display = document }
        else {
            display = PDFDocument()
            for number in state.displayOrder {
                guard let page = document.page(at:number - 1), let copy = page.copy() as? PDFPage else { throw VaultPDFViewState.ViewError.invalid }
                let rect = try number == physicalPage + 1 && reveal ? page.bounds(for:.cropBox) : cropRect(state,physicalPage:number - 1)
                copy.setBounds(rect,for:.cropBox)
                guard (copy.string ?? "").utf8.elementsEqual((page.string ?? "").utf8) else { throw VaultPDFViewState.ViewError.invalid }
                display.insert(copy,at:display.pageCount)
            }
        }
        guard let target = display.page(at:index) else { throw VaultPDFViewState.ViewError.invalid }
        let shownSelection = try selection.map { try translate($0,from:original,to:target,in:display) }
        viewState = state; displayedDocument = display; sourceRevealed = reveal
        view.clearSelection(); view.document = display; view.go(to:target)
        if let shownSelection { view.setCurrentSelection(shownSelection,animate:false); view.go(to:shownSelection) }
        pageChanged()
    }

    func applyViewState(_ state: VaultPDFViewState) throws {
        _ = try state.validated(snapshot:snapshot,pageCount:pageCount)
        guard state != viewState else { return }
        let old = viewState, selection = try originalSelection()
        try install(state,physicalPage:pageIndex,selection:selection)
        viewUndo.append(old); if viewUndo.count > 32 { viewUndo.removeFirst() }; viewRedo.removeAll()
    }

    func moveDisplayPage(from: Int, to: Int) throws {
        guard from > 0, to > 0, from <= pageCount, to <= pageCount else { throw VaultPDFViewState.ViewError.invalid }
        var state = viewState; let page = state.displayOrder.remove(at:from - 1); state.displayOrder.insert(page,at:to - 1)
        try applyViewState(state)
    }

    func setCrop(_ crop: VaultPDFViewState.Crop, physicalPageNumber: Int) throws {
        guard physicalPageNumber > 0, physicalPageNumber <= pageCount else { throw VaultPDFViewState.ViewError.invalid }
        var state = viewState; state.crops[physicalPageNumber - 1] = crop; try applyViewState(state)
    }

    func setBookmark(_ included: Bool, physicalPageNumber: Int) throws {
        guard physicalPageNumber > 0, physicalPageNumber <= pageCount else { throw VaultPDFViewState.ViewError.invalid }
        var state = viewState
        if included {
            if !state.bookmarks.contains(physicalPageNumber) { state.bookmarks.append(physicalPageNumber) }
        } else { state.bookmarks.removeAll { $0 == physicalPageNumber } }
        try applyViewState(state)
    }

    func undoViewState() throws {
        guard let state = viewUndo.last else { return }
        let old = viewState; try install(state,physicalPage:pageIndex,selection:originalSelection())
        viewUndo.removeLast(); viewRedo.append(old)
    }

    func redoViewState() throws {
        guard let state = viewRedo.last else { return }
        let old = viewState; try install(state,physicalPage:pageIndex,selection:originalSelection())
        viewRedo.removeLast(); viewUndo.append(old)
    }

    func applyViewStateNote(_ note: VaultNoteSnapshot) throws {
        try VaultPDFViewState.SaveRequest.checkHeld(note)
        guard !hasViewEdits else { throw VaultPDFViewState.ViewError.unconfirmed }
        _ = try note.validated(at:viewState.notePath)
        let state = try VaultPDFViewState.parse(note.text,snapshot:snapshot,pageCount:pageCount)
        try install(state,physicalPage:pageIndex,selection:originalSelection())
        savedViewState = state; sidecarLoaded = true; viewUndo.removeAll(); viewRedo.removeAll()
    }

    func prepareViewStateSave(base: VaultNoteSnapshot?) throws -> VaultPDFViewState.SaveRequest {
        guard view.document === displayedDocument else { throw VaultPDFError.changed }
        if let base {
            _ = try base.validated(at:viewState.notePath); try VaultPDFViewState.SaveRequest.checkHeld(base)
            guard try VaultPDFViewState.parse(base.text,snapshot:snapshot,pageCount:pageCount) == savedViewState else { throw VaultPDFViewState.ViewError.unconfirmed }
        } else if sidecarLoaded { throw VaultPDFViewState.ViewError.unconfirmed }
        return try .init(state:viewState,base:base)
    }

    func confirmViewStateSave(_ request: VaultPDFViewState.SaveRequest, note: VaultNoteSnapshot) throws {
        _ = try request.state.validated(snapshot:snapshot,pageCount:pageCount); _ = try request.confirmed(note)
        savedViewState = request.state; sidecarLoaded = true
    }

    func returnToSource(_ source: VaultPDFExcerpt) throws {
        guard view.document === displayedDocument else { throw VaultPDFError.changed }
        let (_,page,selection) = try source.sourcePage(in:snapshot)
        guard let original = document.page(at:source.pageIndex) else { throw VaultPDFError.changed }
        let canonical = try translate(selection,from:page,to:original,in:document)
        try install(viewState,physicalPage:source.pageIndex,selection:canonical)
    }

    private static func outlinePageNumber(_ outline: PDFOutline, in document: PDFDocument) -> Int? {
        if let action = outline.action, !(action is PDFActionGoTo) { return nil }
        let destination = (outline.action as? PDFActionGoTo)?.destination ?? outline.destination
        guard let page = destination?.page, page.document === document else { return nil }
        let index = document.index(for:page)
        return index != NSNotFound && index >= 0 && index < document.pageCount ? index + 1 : nil
    }

    private static func readOutline(in document: PDFDocument) -> ([OutlineEntry],Bool) {
        guard let root = document.outlineRoot else { return ([],false) }
        var entries = [OutlineEntry](), truncated = false, inspected = 0
        var seen: Set<ObjectIdentifier> = [ObjectIdentifier(root)]
        var stack: [(PDFOutline,Int,Int)] = [(root,0,0)]
        while let (parent,index,depth) = stack.popLast() {
            guard index < parent.numberOfChildren else { continue }
            guard inspected < outlineEntryLimit else { truncated = true; break }
            inspected += 1
            stack.append((parent,index + 1,depth))
            guard let child = parent.child(at:index), seen.insert(ObjectIdentifier(child)).inserted else {
                truncated = true
                continue
            }
            let title = child.label.flatMap { $0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil : $0 }
            entries.append(.init(id:entries.count,title:title ?? "제목 없는 목차",depth:depth,
                                 pageNumber:outlinePageNumber(child,in:document),outline:child))
            if child.numberOfChildren > 0 {
                if depth < outlineDepthLimit { stack.append((child,0,depth + 1)) }
                else { truncated = true }
            }
        }
        return (entries,truncated)
    }

    @discardableResult
    func go(toOutlineEntry entry: OutlineEntry) -> Bool {
        guard view.document === displayedDocument, document.outlineRoot === outlineRoot,
              outlineEntries.contains(where:{ $0.id == entry.id && $0.outline === entry.outline }),
              let number = entry.pageNumber, Self.outlinePageNumber(entry.outline,in:document) == number else { return false }
        return go(toPageNumber:number)
    }

    nonisolated func pdfViewWillClick(onLink sender: PDFView, with url: URL) {}

    func excerpt() throws -> VaultPDFExcerpt {
        guard let selection = try originalSelection() else { throw VaultPDFError.selection }
        return try VaultPDFExcerpt.capture(snapshot:snapshot,document:document,selection:selection)
    }
}

struct VaultPDFPageControls: View {
    @ObservedObject var reader: VaultPDFReader
    @State private var pageInput = ""
    @State private var notice = ""

    var body: some View {
        VStack(spacing:4) {
            HStack {
                Button("이전 쪽") { _ = reader.go(toDisplayPageNumber:reader.displayPageNumber - 1) }
                    .disabled(reader.displayPageNumber <= 1).frame(minHeight:44)
                Text("원문 \(reader.pageNumber)쪽 · \(reader.displayPageNumber) / \(reader.pageCount)").monospacedDigit()
                    .accessibilityIdentifier("pdfCurrentPage")
                Button("다음 쪽") { _ = reader.go(toDisplayPageNumber:reader.displayPageNumber + 1) }
                    .disabled(reader.displayPageNumber >= reader.pageCount).frame(minHeight:44)
            }
            HStack {
                TextField("쪽 번호",text:$pageInput).keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder).frame(width:70).onSubmit { navigate() }
                    .accessibilityIdentifier("pdfPageNumber")
                Button("이동") { navigate() }.frame(minHeight:44)
            }
            if reader.outlineEntries.isEmpty {
                Text("내장 목차 없음").font(.caption)
            } else {
                Menu("목차") {
                    ForEach(reader.outlineEntries) { entry in
                        Button {
                            if !reader.go(toOutlineEntry:entry) {
                                notice = "이 목차의 이동할 쪽을 확인하지 못했습니다. 현재 페이지와 선택은 유지했습니다."
                            }
                        } label: {
                            Text("\(String(repeating:"　",count:entry.depth))\(entry.title) · \(entry.pageNumber.map { "\($0)쪽" } ?? "이동할 쪽 없음")")
                        }
                        .disabled(entry.pageNumber == nil)
                        .accessibilityLabel(entry.title)
                        .accessibilityValue(entry.pageNumber.map { "\($0)쪽" } ?? "이동할 쪽 없음")
                    }
                }.frame(minHeight:44).accessibilityIdentifier("pdfOutline")
            }
            if reader.outlineTruncated {
                Text("목차는 깊이 \(VaultPDFReader.outlineDepthLimit + 1)단계·\(VaultPDFReader.outlineEntryLimit)항목까지만 표시합니다.")
                    .font(.caption)
            }
            if let selected = reader.selectionPageNumber {
                Text("발췌할 텍스트 선택 · \(selected)쪽").font(.caption)
            }
            if reader.sourceRevealed {
                Text("원문 발췌를 보이기 위해 이 쪽을 잠시 전체 보기로 표시합니다. 저장된 자르기는 유지됩니다.").font(.caption)
            }
            if !notice.isEmpty { Text(notice).font(.footnote).foregroundStyle(.orange) }
        }
        .onAppear { pageInput = String(reader.displayPageNumber) }
        .onChange(of:reader.displayPageNumber) { _,number in pageInput = String(number); notice = "" }
    }

    private func navigate() {
        guard let number = Int(pageInput.trimmingCharacters(in:.whitespacesAndNewlines)),
              reader.go(toDisplayPageNumber:number) else {
            notice = "1부터 \(reader.pageCount)까지의 쪽 번호를 입력하세요. 현재 페이지와 선택은 유지했습니다."
            return
        }
        pageInput = String(reader.displayPageNumber)
        notice = ""
    }
}

struct VaultPDFViewStateControls: View {
    @ObservedObject var reader: VaultPDFReader
    let base: VaultNoteSnapshot?
    let canEdit: Bool
    let canPersist: Bool
    let onSave: (VaultPDFViewState.SaveRequest) -> Void
    let onReload: () -> Void
    @State private var cropInput = "0, 0, 1, 1"
    @State private var notice = ""

    var body: some View {
        VStack {
            Text("원문 \(reader.pageNumber)쪽 · \(reader.viewState.bookmarks.contains(reader.pageNumber) ? "책갈피 있음" : "책갈피 없음")")
                .accessibilityIdentifier("pdfBookmarkCurrentPage")
            Button("현재 쪽 책갈피 추가") { edit { try reader.setBookmark(true,physicalPageNumber:reader.pageNumber) } }
                .disabled(!canEdit || reader.viewState.bookmarks.contains(reader.pageNumber))
                .accessibilityIdentifier("pdfBookmarkAdd")
            Menu("책갈피 목록 · \(reader.viewState.bookmarks.count)개") {
                ForEach(reader.viewState.bookmarks,id:\.self) { number in
                    Button("원문 \(number)쪽으로 이동\(number == reader.pageNumber ? " · 현재 쪽" : "")") {
                        if !reader.go(toPageNumber:number) { notice = "책갈피의 원문 쪽으로 이동하지 못했습니다. 현재 페이지와 선택을 유지합니다." }
                    }
                    Button("원문 \(number)쪽 책갈피 제거",role:.destructive) {
                        edit { try reader.setBookmark(false,physicalPageNumber:number) }
                    }.disabled(!canEdit)
                }
            }.disabled(reader.viewState.bookmarks.isEmpty).accessibilityIdentifier("pdfBookmarkList")
            Text("책갈피 추가·제거는 보기 설정 Markdown 저장으로 확정합니다.").font(.caption)
            HStack {
                Button("표시 순서 위로") { edit { try reader.moveDisplayPage(from:reader.displayPageNumber,to:reader.displayPageNumber - 1) } }
                    .disabled(!canEdit || reader.displayPageNumber <= 1)
                Button("표시 순서 아래로") { edit { try reader.moveDisplayPage(from:reader.displayPageNumber,to:reader.displayPageNumber + 1) } }
                    .disabled(!canEdit || reader.displayPageNumber >= reader.pageCount)
            }
            Text("자르기 · 원문 \(reader.pageNumber)쪽의 PDF 좌표 비율 x, y, width, height").font(.caption)
            TextField("0, 0, 1, 1",text:$cropInput).textFieldStyle(.roundedBorder).disabled(!canEdit)
            HStack {
                Button("자르기 적용") {
                    edit {
                        let parts = cropInput.components(separatedBy:",")
                        guard parts.count == 4 else { throw VaultPDFViewState.ViewError.invalid }
                        let values = parts.map { Double($0.trimmingCharacters(in:.whitespaces)) }
                        guard let x = values[0], let y = values[1], let width = values[2], let height = values[3] else { throw VaultPDFViewState.ViewError.invalid }
                        try reader.setCrop(.init(x:x,y:y,width:width,height:height),physicalPageNumber:reader.pageNumber)
                    }
                }.disabled(!canEdit)
                Button("이 쪽 자르기 원복") { edit { try reader.setCrop(.init(),physicalPageNumber:reader.pageNumber) } }.disabled(!canEdit)
            }
            HStack {
                Button("보기 설정 실행 취소") { edit { try reader.undoViewState() } }.disabled(!canEdit || !reader.canUndoViewState)
                Button("보기 설정 다시 실행") { edit { try reader.redoViewState() } }.disabled(!canEdit || !reader.canRedoViewState)
            }
            HStack {
                Button("보기 설정 Markdown 저장") { edit { onSave(try reader.prepareViewStateSave(base:base)) } }.disabled(!canPersist)
                Button("보기 설정 원본 재조회") { onReload() }.disabled(!canPersist || reader.hasViewEdits)
            }
            if !notice.isEmpty { Text(notice).font(.footnote) }
        }.buttonStyle(.bordered).controlSize(.large)
        .onAppear { syncCropInput() }
        .onChange(of:reader.pageIndex) { _,_ in syncCropInput() }
        .onChange(of:reader.viewState) { _,_ in syncCropInput() }
    }

    private func edit(_ action: () throws -> Void) {
        do { try action(); notice = "" } catch { notice = error.localizedDescription }
    }

    private func syncCropInput() {
        let crop = reader.viewState.crops[reader.pageIndex]
        cropInput = "\(crop.x), \(crop.y), \(crop.width), \(crop.height)"
    }
}

struct VaultPDFView: UIViewRepresentable {
    let reader: VaultPDFReader
    func makeUIView(context: Context) -> PDFView { reader.view }
    func updateUIView(_ view: PDFView, context: Context) {}
}
