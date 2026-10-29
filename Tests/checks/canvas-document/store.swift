import Foundation
import PencilKit
@main struct DocumentStoreChecks {
    @MainActor static func main() async throws {
        guard case .isolated = CanvasRuntime.launch else { fatalError("isolated required") }
        let store = CanvasStore(); store.enableDocumentChecks()
        try store.createDocument()
        precondition(store.isDocumentSource && store.document.pages.count == 1)
        print("PASS actual Store Document ingress")
    }
}
