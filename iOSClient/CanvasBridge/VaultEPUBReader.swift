import SwiftUI
#if canImport(UIKit)
import UIKit
typealias VaultEPUBTextView = UITextView
#else
import AppKit
typealias VaultEPUBTextView = NSTextView
#endif

@MainActor final class VaultEPUBReader: NSObject, ObservableObject {
    let book: VaultEPUBBook
    let view: VaultEPUBTextView
    @Published private(set) var chapterIndex = 0
    @Published private(set) var fontSize: Double = 18
    @Published private(set) var pendingExcerpt: VaultEPUBExcerpt?
    @Published var status = "원문 한 문단의 글자를 선택해 발췌하세요."
    enum SearchState: Equatable { case idle, searching, complete(more: Bool), invalid }
    struct SearchResult: Identifiable, Equatable {
        let anchor: VaultEPUBExcerpt
        let chapterNumber: Int, paragraphNumber: Int
        let preview: String
        var id: UUID { anchor.excerptID }
        fileprivate let readerID: UUID, generation: UUID
    }
    static let searchQueryLimit = 256 // UTF16 units; native selections use the same coordinate system.
    static let searchResultLimit = 200
    @Published private(set) var searchQuery = ""
    @Published private(set) var searchState = SearchState.idle
    @Published private(set) var searchResults = [SearchResult]()
    private let searchReaderID = UUID()
    private var searchGeneration = UUID()
    var searchNotice: String {
        switch searchState {
        case .idle: return "현재 열린 EPUB 한 권의 본문에서 검색하세요."
        case .searching: return "본문 검색 중…"
        case .invalid: return "검색어는 UTF16 \(Self.searchQueryLimit)칸 이하로 입력하세요."
        case .complete(let more): return more ? "결과가 더 있습니다. 앞 \(Self.searchResultLimit)개를 표시합니다. 검색어를 좁혀 주세요." : "검색 완료 · \(searchResults.count)개 결과"
        }
    }
    func updateSearchQuery(_ query: String) {
        guard !query.utf8.elementsEqual(searchQuery.utf8) else { return }
        cancelSearch(); searchQuery = query
        if query.utf16.count > Self.searchQueryLimit { searchState = .invalid }
    }
    func cancelSearch() { searchGeneration = UUID(); searchResults = []; searchState = .idle }
    func clearSearch() { cancelSearch(); searchQuery = "" }

    func search() async {
        cancelSearch()
        let query = searchQuery, generation = searchGeneration
        guard query.utf16.count <= Self.searchQueryLimit else { searchState = .invalid; return }
        guard !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        searchState = .searching
        var found = [SearchResult](), more = false
        // ponytail: bounded linear scan of the already decoded book; no second index or normalized source copy.
        chapters: for (chapterIndex,chapter) in book.chapters.enumerated() {
            for (paragraphIndex,paragraph) in chapter.paragraphs.enumerated() {
                await Task.yield()
                guard !Task.isCancelled, generation == searchGeneration else {
                    if generation == searchGeneration { cancelSearch() }; return
                }
                var cursor = paragraph.text.startIndex
                while cursor < paragraph.text.endIndex,
                      let range = paragraph.text.range(of:query,options:.caseInsensitive,
                          range:cursor..<paragraph.text.endIndex,locale:Locale(identifier:"en_US_POSIX")) {
                    guard !range.isEmpty else { break }
                    if found.count == Self.searchResultLimit { more = true; break chapters }
                    do {
                        let anchor = try VaultEPUBExcerpt.capture(book:book,chapter:chapterIndex,paragraph:paragraphIndex,
                            range:NSRange(range,in:paragraph.text))
                        let lower = paragraph.text.index(range.lowerBound,offsetBy:-32,limitedBy:paragraph.text.startIndex) ?? paragraph.text.startIndex
                        let upper = paragraph.text.index(range.upperBound,offsetBy:64,limitedBy:paragraph.text.endIndex) ?? paragraph.text.endIndex
                        let preview = (lower == paragraph.text.startIndex ? "" : "…") + String(paragraph.text[lower..<upper]) + (upper == paragraph.text.endIndex ? "" : "…")
                        found.append(.init(anchor:anchor,chapterNumber:chapterIndex+1,paragraphNumber:paragraphIndex+1,
                            preview:preview,readerID:searchReaderID,generation:generation))
                    } catch {
                        // An unrepresentable source anchor must never become a guessed search location.
                        if generation == searchGeneration { cancelSearch(); status = "검색 결과의 원문 위치를 확인하지 못했습니다. 원본과 발췌 입력을 유지합니다." }; return
                    }
                    cursor = range.upperBound
                }
            }
        }
        guard !Task.isCancelled, generation == searchGeneration else {
            if generation == searchGeneration { cancelSearch() }; return
        }
        searchResults = found; searchState = .complete(more:more)
    }
    @discardableResult func revealSearchResult(_ result: SearchResult) -> Bool {
        guard case .complete = searchState, result.readerID == searchReaderID, result.generation == searchGeneration,
              searchResults.contains(result) else {
            status = "검색어나 원문이 바뀌어 이전 검색 결과를 적용하지 않았습니다."; return false
        }
        do { try reveal(result.anchor); return true }
        catch { status = "검색 원문 위치를 확인하지 못했습니다. 현재 페이지와 발췌 입력을 유지합니다."; return false }
    }
    private var ranges: [NSRange] = []
    init(snapshot: VaultEPUBSnapshot) throws {
        book = try VaultEPUBBook(snapshot:snapshot)
        #if canImport(UIKit)
        view = UITextView(frame:.zero)
        view.dataDetectorTypes = []; view.isEditable = false; view.isSelectable = true
        #else
        view = NSTextView(frame:CGRect(x:0,y:0,width:640,height:900))
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.textContainer?.widthTracksTextView = true
        #endif
        super.init(); render(chapter:0,selection:NSRange(location:0,length:0))
    }
    private var selection: NSRange {
        #if canImport(UIKit)
        return view.selectedRange
        #else
        return view.selectedRange()
        #endif
    }
    private func select(_ range: NSRange) {
        #if canImport(UIKit)
        view.selectedRange = range
        #else
        view.setSelectedRange(range)
        #endif
        view.scrollRangeToVisible(range)
    }
    private func render(chapter: Int, selection: NSRange) {
        let paragraphs = book.chapters[chapter].paragraphs
        var text = ""; ranges = []
        for paragraph in paragraphs {
            if !text.isEmpty { text += "\n\n" }
            ranges.append(NSRange(location:text.utf16.count,length:paragraph.text.utf16.count)); text += paragraph.text
        }
        #if canImport(UIKit)
        let styled = NSAttributedString(string:text,attributes:[.font:UIFont.systemFont(ofSize:CGFloat(fontSize)),.foregroundColor:UIColor.label])
        view.attributedText = styled
        #else
        let styled = NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:CGFloat(fontSize)),.foregroundColor:NSColor.labelColor])
        view.textStorage?.setAttributedString(styled)
        #endif
        chapterIndex = chapter; select(selection)
    }
    func openChapter(_ chapter: Int, fragment: String? = nil) throws {
        guard book.chapters.indices.contains(chapter) else { throw VaultEPUBError.invalid }
        let paragraph: Int
        if let fragment {
            guard let index = book.chapters[chapter].paragraphs.firstIndex(where:{$0.fragment?.utf8.elementsEqual(fragment.utf8) == true}) else { throw VaultEPUBError.changed }
            paragraph = index
        } else { paragraph = 0 }
        let location = book.chapters[chapter].paragraphs.prefix(paragraph).reduce(0) { $0 + $1.text.utf16.count+2 }
        render(chapter:chapter,selection:NSRange(location:location,length:0))
    }
    func setFontSize(_ size: Double) throws {
        guard size.isFinite, (10...48).contains(size) else { throw VaultEPUBError.invalid }
        let current = selection
        fontSize = size; render(chapter:chapterIndex,selection:current)
    }
    func capture(_ chosen: NSRange? = nil) throws -> VaultEPUBExcerpt {
        let chosen = chosen ?? selection
        guard chosen.location != NSNotFound, chosen.location >= 0, chosen.length > 0,
              chosen.location <= Int.max-chosen.length,
              let index = ranges.firstIndex(where:{NSLocationInRange(chosen.location,$0) && NSMaxRange(chosen) <= NSMaxRange($0)}) else { throw VaultEPUBError.selection }
        return try VaultEPUBExcerpt.capture(book:book,chapter:chapterIndex,paragraph:index,
            range:NSRange(location:chosen.location-ranges[index].location,length:chosen.length))
    }
    func reveal(_ excerpt: VaultEPUBExcerpt) throws {
        let source = try excerpt.resolve(in:book)
        let start = book.chapters[source.chapter].paragraphs.prefix(source.paragraph).reduce(0) { $0 + $1.text.utf16.count+2 }
        render(chapter:source.chapter,selection:NSRange(location:start+source.range.location,length:source.range.length))
    }
    func prepareExcerpt() throws -> VaultEPUBExcerpt {
        if let pendingExcerpt { return pendingExcerpt }
        let excerpt = try capture(); pendingExcerpt = excerpt; return excerpt
    }
    func acceptSavedNote(_ note: VaultNoteSnapshot, relayAddress: String) throws -> VaultNoteReference {
        guard let pending = pendingExcerpt else { throw VaultEPUBError.invalid }
        let reference = try pending.reference(note:note,relayAddress:relayAddress)
        pendingExcerpt = nil; status = "EPUB 원문과 연결된 노트의 저장·재열기를 확인했습니다."
        return reference
    }
}

#if canImport(UIKit)
private struct EPUBNativeText: UIViewRepresentable {
    let reader: VaultEPUBReader
    func makeUIView(context: Context) -> UITextView { reader.view }
    func updateUIView(_ view: UITextView, context: Context) {}
}
#else
private struct EPUBNativeText: NSViewRepresentable {
    let reader: VaultEPUBReader
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = reader.view
        reader.view.isVerticallyResizable = true; reader.view.autoresizingMask = [.width]
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {}
}
#endif

/// The owner must persist the existing durable note-create intent, then PUT+GET before returning a snapshot.
/// This view never starts a network connection, opens a URL, or creates a parallel note database.
struct VaultEPUBReaderPanel: View {
    @ObservedObject var reader: VaultEPUBReader
    let relayAddress: String
    let saveNote: @MainActor (VaultEPUBExcerpt,String) async throws -> VaultNoteSnapshot
    let attachReference: @MainActor (VaultNoteReference) throws -> Void
    let isCurrent: @MainActor () -> Bool
    @State private var saving = false
    @State private var requestID = UUID()
    @State private var saveTask: Task<Void,Never>?
    var body: some View {
        VStack {
            HStack {
                Menu("목차·장") {
                    ForEach(reader.book.toc) { entry in
                        Button(entry.title) { run { try reader.openChapter(entry.chapter,fragment:entry.fragment) } }
                    }
                    ForEach(reader.book.chapters.indices,id:\.self) { index in
                        Button("장 \(index+1)") { run { try reader.openChapter(index) } }
                    }
                }
                Button("글꼴 축소") { run { try reader.setFontSize(max(10,reader.fontSize-2)) } }
                Button("글꼴 확대") { run { try reader.setFontSize(min(48,reader.fontSize+2)) } }
                Button(saving ? "저장 확인 중" : reader.pendingExcerpt == nil ? "선택 발췌·노트 저장" : "같은 발췌 저장 재확인") {
                    guard isCurrent() else { return }
                    let request = UUID(); requestID = request; saving = true
                    saveTask = Task { @MainActor in
                        defer { if requestID == request { saving = false } }
                        do {
                            guard isCurrent(), !Task.isCancelled, requestID == request else { throw VaultEPUBError.changed }
                            let excerpt = try reader.prepareExcerpt(), markdown = try excerpt.markdown()
                            let note = try await saveNote(excerpt,markdown)
                            guard isCurrent(), !Task.isCancelled, requestID == request else { throw VaultEPUBError.changed }
                            let reference = try excerpt.reference(note:note,relayAddress:relayAddress)
                            try attachReference(reference)
                            _ = try reader.acceptSavedNote(note,relayAddress:relayAddress)
                        } catch { reader.status = "발췌 ID와 입력을 유지합니다. " + error.localizedDescription }
                    }
                }.disabled(saving)
            }
            VaultEPUBSearchControls(reader:reader,isCurrent:isCurrent)
            EPUBNativeText(reader:reader)
            Text(reader.status).font(.footnote)
            Text("장 \(reader.chapterIndex+1)/\(reader.book.chapters.count) · 원문 SHA \(reader.book.snapshot.sha256)").font(.caption)
        }.padding().onDisappear { requestID = UUID(); saveTask?.cancel(); saving = false }
    }
    private func run(_ action: () throws -> Void) {
        do { try action() } catch { reader.status = error.localizedDescription }
    }
}

/// The Store adapter can reuse this view with its existing Reader/connection ownership guard.
struct VaultEPUBSearchControls: View {
    @ObservedObject var reader: VaultEPUBReader
    let isCurrent: @MainActor () -> Bool
    @State private var task: Task<Void,Never>?
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                TextField("이 EPUB 본문 검색",text:Binding(get:{reader.searchQuery},set:{ reader.updateSearchQuery($0) }))
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("epubSearchQuery")
                    .onSubmit { search() }
                Button("검색") { search() }.accessibilityIdentifier("epubSearchSubmit")
                Button("지우기") { task?.cancel(); reader.clearSearch() }.accessibilityIdentifier("epubSearchClear")
            }
            Text(reader.searchNotice).font(.caption).accessibilityIdentifier("epubSearchStatus")
            if !reader.searchResults.isEmpty {
                ScrollView {
                    LazyVStack(alignment:.leading) {
                        ForEach(reader.searchResults) { result in
                            Button {
                                guard isCurrent() else { return }
                                _ = reader.revealSearchResult(result)
                            } label: {
                                VStack(alignment:.leading) {
                                    Text("장 \(result.chapterNumber) · 문단 \(result.paragraphNumber)").font(.caption)
                                    Text(result.preview).multilineTextAlignment(.leading)
                                }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,6)
                            }.buttonStyle(.plain).accessibilityIdentifier("epubSearchResult-\(result.id.uuidString)")
                        }
                    }
                }.frame(maxHeight:220)
            }
            Text("현재 책의 문단 안 문자열 검색 · 대소문자 구분 없음 · 문서 간·OCR 검색은 지원하지 않습니다.").font(.caption)
        }
        .onDisappear { task?.cancel(); reader.cancelSearch() }
    }
    private func search() {
        guard isCurrent() else { return }
        task?.cancel()
        task = Task { @MainActor in
            guard isCurrent(), !Task.isCancelled else { return }
            await reader.search()
            if !isCurrent() { reader.cancelSearch() }
        }
    }
}
