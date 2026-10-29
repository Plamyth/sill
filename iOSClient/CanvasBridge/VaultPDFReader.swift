import SwiftUI
import PDFKit

private final class VaultReadOnlyPDFView: PDFView {
    override func perform(_ action: PDFAction) {
        if action is PDFActionGoTo { super.perform(action) }
    }
}

@MainActor final class VaultPDFReader: NSObject, ObservableObject, PDFViewDelegate {
    let snapshot: VaultPDFSnapshot
    let view: PDFView
    private let document: PDFDocument
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
        let index = document.index(for:page)
        return index == NSNotFound ? nil : index + 1
    }

    init(snapshot: VaultPDFSnapshot, source: VaultPDFExcerpt? = nil) throws {
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
        outlineRoot = opened.outlineRoot
        (outlineEntries,outlineTruncated) = Self.readOutline(in:opened)
        view = VaultReadOnlyPDFView()
        super.init()
        view.delegate = self
        view.isInMarkupMode = false
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = document
        NotificationCenter.default.addObserver(self,selector:#selector(pageChanged),name:.PDFViewPageChanged,object:view)
        NotificationCenter.default.addObserver(self,selector:#selector(selectionChanged),name:.PDFViewSelectionChanged,object:view)
        if let (page,selection) = anchor {
            view.go(to:page)
            view.setCurrentSelection(selection,animate:false)
            view.go(to:selection)
        }
        pageChanged()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func pageChanged() {
        guard view.document === document, let page = view.currentPage else { return }
        let index = document.index(for:page)
        if index != NSNotFound { pageIndex = index }
    }

    @objc private func selectionChanged() { objectWillChange.send() }

    @discardableResult
    func go(toPageNumber number: Int) -> Bool {
        guard number > 0, number <= pageCount, view.document === document,
              let page = document.page(at:number - 1) else { return false }
        view.clearSelection()
        view.go(to:page)
        pageChanged()
        return view.currentPage === page
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
        guard view.document === document, document.outlineRoot === outlineRoot,
              outlineEntries.contains(where:{ $0.id == entry.id && $0.outline === entry.outline }),
              let number = entry.pageNumber, Self.outlinePageNumber(entry.outline,in:document) == number else { return false }
        return go(toPageNumber:number)
    }

    nonisolated func pdfViewWillClick(onLink sender: PDFView, with url: URL) {}

    func excerpt() throws -> VaultPDFExcerpt {
        guard view.document === document, let selection = view.currentSelection else { throw VaultPDFError.selection }
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
                Button("이전 쪽") { _ = reader.go(toPageNumber:reader.pageNumber - 1) }
                    .disabled(reader.pageNumber <= 1).frame(minHeight:44)
                Text("\(reader.pageNumber) / \(reader.pageCount)쪽").monospacedDigit()
                    .accessibilityIdentifier("pdfCurrentPage")
                Button("다음 쪽") { _ = reader.go(toPageNumber:reader.pageNumber + 1) }
                    .disabled(reader.pageNumber >= reader.pageCount).frame(minHeight:44)
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
            if !notice.isEmpty { Text(notice).font(.footnote).foregroundStyle(.orange) }
        }
        .onAppear { pageInput = String(reader.pageNumber) }
        .onChange(of:reader.pageNumber) { _,number in pageInput = String(number); notice = "" }
    }

    private func navigate() {
        guard let number = Int(pageInput.trimmingCharacters(in:.whitespacesAndNewlines)),
              reader.go(toPageNumber:number) else {
            notice = "1부터 \(reader.pageCount)까지의 쪽 번호를 입력하세요. 현재 페이지와 선택은 유지했습니다."
            return
        }
        pageInput = String(reader.pageNumber)
        notice = ""
    }
}

struct VaultPDFView: UIViewRepresentable {
    let reader: VaultPDFReader
    func makeUIView(context: Context) -> PDFView { reader.view }
    func updateUIView(_ view: PDFView, context: Context) {}
}
