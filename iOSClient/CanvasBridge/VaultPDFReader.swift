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

    init(snapshot: VaultPDFSnapshot, source: VaultPDFExcerpt? = nil) throws {
        let bytes = try snapshot.bytes(at:snapshot.path)
        self.snapshot = snapshot
        view = VaultReadOnlyPDFView()
        super.init()
        view.delegate = self
        view.isInMarkupMode = false
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        if let source {
            let (document,page,selection) = try source.sourcePage(in:snapshot)
            view.document = document
            view.go(to:page)
            view.setCurrentSelection(selection,animate:false)
            view.go(to:selection)
        } else {
            guard let document = PDFDocument(data:bytes), !document.isLocked else { throw VaultPDFError.invalid }
            view.document = document
        }
    }

    nonisolated func pdfViewWillClick(onLink sender: PDFView, with url: URL) {}

    func excerpt() throws -> VaultPDFExcerpt {
        guard let document = view.document, let selection = view.currentSelection else { throw VaultPDFError.selection }
        return try VaultPDFExcerpt.capture(snapshot:snapshot,document:document,selection:selection)
    }
}

struct VaultPDFView: UIViewRepresentable {
    let reader: VaultPDFReader
    func makeUIView(context: Context) -> PDFView { reader.view }
    func updateUIView(_ view: PDFView, context: Context) {}
}
