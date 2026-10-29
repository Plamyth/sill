# EPUB Reader 본문 검색 검사

실행: `python3 -B Tests/checks/epub-reader-search/run.py --output ABSOLUTE_STORAGE_ROUTE_PATH`

기존 epub-source runner의 실제 SDK27 native 방식만 재사용한다. 제품4입력(Model/EPUB/Excerpt/Reader)과 현재 전체Canvas iOS SDK입력을 기록하고 전후SHA를 비교한다. 새 engine/mock/URLProtocol/HTTP/앱/권한/UI/기기/Host가 없다. 원문은 고정 ZIP metadata의 자체2장 표본이며 NFC/NFD·emoji·여러 문단과 200/205회 반복을 포함한다. 기존 원앱 archive나 개인 자료를 복사하지 않는다. 처음 실행한 모든 결과·실패는 evidence에 보존하며 원본 입력/normal 상태를 쓰지 않는다.

결과 JSON의 실행 HEAD는 구현 전 base+dirty일 수 있으므로 최종 HANDOFF의 Git blob SHA 결속을 함께 본다. 실제 Workspace는 다른 owner의 StoreReader를 소비하므로 모듈 Panel/native 검사가 실제 앱 검색 노출 수용을 뜻하지 않는다. 자세한 부모 한 줄 접합 요구는 docs/epub-reader-search.md에 있다.
