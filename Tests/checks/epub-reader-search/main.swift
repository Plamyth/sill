import Foundation
import AppKit

@main struct EPUBReaderSearchChecks {
    @MainActor static var checks = [String]()
    @MainActor static func check(_ condition: Bool, _ text: String) throws {
        guard condition else { throw NSError(domain:"EPUBReaderSearchChecks",code:1,userInfo:[NSLocalizedDescriptionKey:text]) }
        checks.append(text); print("PASS",text)
    }
    @MainActor static func main() async throws {
        let out = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let file = out.appendingPathComponent("own.epub"), bytes = try Data(contentsOf:file)
        let snapshot = try VaultEPUBSnapshot(path:"Own/검색.epub",bytes:bytes)
        let reader = try VaultEPUBReader(snapshot:snapshot)
        let windows = NSApplication.shared.windows.count
        try check(reader.searchState == .idle && reader.searchResults.isEmpty,"새 Reader 검색 상태는 idle·빈 결과")
        reader.updateSearchQuery("가나다"); await reader.search()
        try check(reader.searchResults.count == 3 && reader.searchState == .complete(more:false),"한글 문자열이 여러 장·문단에서 검색되고 완료 건수 명시")
        let results = reader.searchResults
        try check(results.map(\.chapterNumber) == [1,1,2] && results.map(\.paragraphNumber) == [1,2,1],"검색 순서는 원문 장·문단 순서")
        for result in results {
            let anchor = result.anchor, resolved = try anchor.resolve(in:reader.book)
            try check(anchor.sourceID == snapshot.sourceID && anchor.sourceSHA256 == snapshot.sha256 && anchor.sourcePath == snapshot.path && !anchor.xpath.isEmpty && resolved.chapter+1 == result.chapterNumber && resolved.paragraph+1 == result.paragraphNumber,"각 결과가 원문 ID/SHA/장/문단/XPath/UTF16 앵커에 결속")
            try check(reader.revealSearchResult(result) && reader.chapterIndex+1 == result.chapterNumber,"실제 native Reader가 결과의 같은 장·문단으로 이동")
            let capture = try reader.capture()
            try check(capture.range == anchor.range && capture.quote.utf8.elementsEqual(anchor.quote.utf8) && capture.spineItem == anchor.spineItem && capture.xpath == anchor.xpath,"이동 뒤 실제 텍스트 선택 capture의 UTF16 quote가 원본 앵커와 일치")
        }
        try check(results[0].anchor.range.location == 6 && results[0].anchor.range.length == 3,"앞선 emoji surrogate를 포함한 원본 UTF16 오프셋")
        try check(results.allSatisfy { $0.preview.contains("가나다") },"결과 미리보기가 원문 문맥을 포함")
        reader.updateSearchQuery("😀"); await reader.search()
        try check(reader.searchResults.count == 2 && reader.searchResults.allSatisfy { $0.anchor.range.length == 2 && $0.anchor.quote == "😀" },"emoji는 surrogate를 자르지 않은 원본 두 UTF16칸")
        reader.updateSearchQuery("é"); await reader.search()
        try check(reader.searchResults.count == 2,"정규형이 다른 같은 문자열을 원문에서 찾음")
        try check(Set(reader.searchResults.map { $0.anchor.quote.utf8.count }) == Set([2,3]) && Set(reader.searchResults.map { $0.anchor.range.length }) == Set([1,2]),"NFC/NFD 결과는 정규화 복사본이 아닌 각각 원래 bytes와 길이 보존")
        for result in reader.searchResults { try check(reader.revealSearchResult(result) && reader.capture().quote.utf8.elementsEqual(result.anchor.quote.utf8),"정규형 검색 후 capture도 원래 인용 bytes 유지") }
        reader.updateSearchQuery("가"); await reader.search()
        try check(!reader.searchResults.isEmpty && reader.searchResults.allSatisfy { $0.anchor.quote == "가" },"분해 한글 질의가 합성 원문에 매칭되고 원문 인용 유지")
        reader.updateSearchQuery("alpha"); await reader.search()
        try check(reader.searchResults.count == 1 && reader.searchResults[0].anchor.quote == "Alpha","대소문자 비구분은 원문 quote의 대소문자를 바꾸지 않음")
        let stale = reader.searchResults[0]
        reader.updateSearchQuery("Beta"); await reader.search()
        let before = reader.chapterIndex, beforeCapture = try reader.capture()
        try check(!reader.revealSearchResult(stale) && reader.chapterIndex == before && reader.capture().range == beforeCapture.range,"질의 교체 후 이전 결과 callback은 장·선택을 바꾸지 않음")
        reader.updateSearchQuery("alpha"); await reader.search()
        try check(!reader.revealSearchResult(stale),"질의 A→B→A 뒤에도 이전 결과 세대 거부")
        let repeatStale = reader.searchResults[0]; await reader.search()
        try check(!reader.revealSearchResult(repeatStale),"같은 질의 재검색도 이전 결과 callback 거부")
        let cleared = reader.searchResults[0]; reader.clearSearch()
        try check(reader.searchQuery.isEmpty && reader.searchState == .idle && !reader.revealSearchResult(cleared),"clear는 질의·목록·이전 결과 소유권을 즉시 무효화")
        reader.updateSearchQuery(" \n\t"); await reader.search()
        try check(reader.searchState == .idle && reader.searchResults.isEmpty,"공백 질의는 본문 전체 일치로 처리하지 않음")
        reader.updateSearchQuery("ZXQ7"); await reader.search()
        try check(reader.searchState == .complete(more:false) && reader.searchResults.isEmpty && reader.searchNotice.contains("0개"),"불일치는 명시 완료0건")
        reader.updateSearchQuery(String(repeating:"😀",count:128)); await reader.search()
        try check(reader.searchState == .complete(more:false),"UTF16 입력 상한256칸은 허용")
        let long = String(repeating:"😀",count:129); reader.updateSearchQuery(long); await reader.search()
        try check(reader.searchState == .invalid && reader.searchQuery == long && reader.searchResults.isEmpty,"UTF16 입력 초과는 숨겨 자르지 않고 입력·오류를 표시")
        reader.updateSearchQuery("needle"); await reader.search()
        try check(reader.searchResults.count == 200 && reader.searchState == .complete(more:true) && reader.searchNotice.contains("더 있습니다"),"200개 초과는 완전 결과라고 숨기지 않고 추가 결과 존재 표시")
        reader.updateSearchQuery("exact"); await reader.search()
        try check(reader.searchResults.count == 200 && reader.searchState == .complete(more:false),"정확히200개 결과와 초과를 구분")
        reader.updateSearchQuery("가나다")
        let oldTask = Task { @MainActor in await reader.search() }
        while reader.searchState != .searching { await Task.yield() }
        reader.updateSearchQuery("Beta"); await oldTask.value
        try check(reader.searchResults.isEmpty && reader.searchQuery == "Beta" && reader.searchState == .idle,"실행 중 질의 교체는 늦은 검색 결과 설치 거부")
        let newTask = Task { @MainActor in await reader.search() }
        while reader.searchState != .searching { await Task.yield() }
        reader.clearSearch(); await newTask.value
        try check(reader.searchQuery.isEmpty && reader.searchResults.isEmpty && reader.searchState == .idle,"실행 중 clear 뒤 늦은 완료는 결과를 되살리지 않음")
        reader.updateSearchQuery("가나다")
        let cancelTask = Task { @MainActor in await reader.search() }
        while reader.searchState != .searching { await Task.yield() }
        cancelTask.cancel(); await cancelTask.value
        try check(reader.searchResults.isEmpty && reader.searchState == .idle,"Task 취소는 부분 결과를 정상 완료로 설치하지 않음")
        await reader.search(); let foreign = reader.searchResults.last!
        let fresh = try VaultEPUBReader(snapshot:snapshot)
        fresh.updateSearchQuery("가나다"); await fresh.search()
        try check(fresh.searchResults.count == 3 && !fresh.revealSearchResult(foreign),"새 Reader는 같은 archive라도 이전 Reader 결과 callback 거부")
        let modified = try VaultEPUBSnapshot(path:snapshot.path,bytes:Data(contentsOf:out.appendingPathComponent("changed.epub")))
        let changed = try VaultEPUBReader(snapshot:modified)
        changed.updateSearchQuery("가나다"); await changed.search()
        try check(!changed.revealSearchResult(foreign),"같은 경로의 다른 SHA 원문에서 이전 결과 거부")
        do { _ = try foreign.anchor.resolve(in:changed.book); throw NSError(domain:"accepted changed SHA",code:1) }
        catch is VaultEPUBError { try check(true,"기존 source 앵커 resolve도 다른 SHA를 독립 거부") }
        let own = fresh.searchResults[0]; try check(fresh.revealSearchResult(own),"새 Reader 자체 검색 결과만 수용")
        let pending = try fresh.prepareExcerpt(), pendingBytes = try JSONEncoder().encode(pending)
        fresh.updateSearchQuery("Beta"); await fresh.search()
        try check(fresh.revealSearchResult(fresh.searchResults[0]),"발췌 대기 중 검색 이동은 읽기만 수행")
        try check(try JSONEncoder().encode(fresh.pendingExcerpt) == pendingBytes && fresh.prepareExcerpt() == pending,"검색/이동은 기존 pendingExcerpt ID·인용·노트 의도를 바꾸지 않음")
        fresh.clearSearch(); try fresh.setFontSize(24)
        try check(fresh.pendingExcerpt == pending && fresh.book.snapshot.sha256 == snapshot.sha256,"clear·리플로 뒤에도 발췌 대기와 immutable 원본 보존")
        try check(try Data(contentsOf:file) == bytes && snapshot.bytes(at:snapshot.path) == bytes && reader.book.snapshot.sha256 == snapshot.sha256,"전체 검색·선택·새 Reader 후 원본 EPUB bytes/SHA 불변")
        try check(NSApplication.shared.windows.count == windows,"실제 native 검색 검사 Window/GUI 생성0")
        let result: [String:Any] = ["passed":true,"checks":checks,"count":checks.count,"sourceSHA256":snapshot.sha256,"changedSHA256":modified.sha256,"HTTP":false,"GUI":false,"device":false,"wholeEPUBAccepted":false]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("observations.json"))
    }
}
