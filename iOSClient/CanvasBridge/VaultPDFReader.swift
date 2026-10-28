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
