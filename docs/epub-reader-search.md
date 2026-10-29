# 현재 열린 EPUB 본문 검색

기준은 공식 c8992bbec29297148eb5a4b69b072fb3d579cdbf / tree b61c8345664b2b2bf96f8b37d6930a7a3ac98588다. R092 `rea-stage1-20261021/margin-search-observed-spec.md`에서 실제 관측한 검색 질의→결과 미리보기→장/문단 이동을 좁게 구현한다. 원앱 Mac의 관측이며 원앱 iPad·OCR·문서 간/스터디셋·정확 문자 가시성·cold restart·전체 동등성은 수용하지 않는다. CCR native의 정확 선택 검증은 CCR 구현 근거로 분리한다.

## 데이터·검색 계약

VaultEPUBReader.swift 하나의 제품 변경이다. immutable `book.chapters[].paragraphs[]`를 Foundation 문자열 검색으로 순회한다. 새 검색엔진/인덱스/DB/provider/네트워크/ZIP parser를 만들지 않는다. 질의는 문단 안의 비중첩 문자열 검색이며 대소문자를 구분하지 않고 Foundation의 Unicode 정규형 일치를 사용한다. 단어 토큰/OCR/정규식/문단을 가로지르는 검색/악센트 무시는 제공하지 않는다. query를 NFC 등으로 재작성한 복사본의 좌표를 원본에 적용하지 않는다.

질의 최대256 UTF16칸, 결과는 처음200개까지다. 초과 입력을 숨겨 자르지 않으며 그대로 두고 오류 상태를 표시한다. 201번째 일치가 있으면 ‘결과가 더 있습니다. 앞200개’라고 표시하며 완전 결과 수라고 주장하지 않는다. 빈/공백 질의는 안내, 불일치는 명시 ‘검색 완료·0개 결과’다. 전체 결과200과 초과를 구분한다. 문단별 `Task.yield`와 취소 검사를 사용해 MainActor를 독점한 채 새 질의/clear를 막지 않는다.

SearchState는 idle/searching/complete(more)/invalid이며 별도 불리언 조합으로 완료를 추정하지 않는다. 질의의 UTF8 bytes가 바뀔 때마다 검색 UUID와 목록을 무효화한다. 새 검색·clear·cancel도 새 세대를 사용한다. 검색 결과는 Reader별 UUID, 검색 UUID, 기존 `VaultEPUBExcerpt.capture`의 sourceID/path/SHA/spine/chapterPath/XPath/UTF16 range/원문 quote에 결속한다. preview는 원래 문자열의 주변32+64 Character 범위이며 원문이 아니다.

결과 선택은 같은 Reader·현재 검색 세대·현재 목록의 동일 결과인지 검사하고 기존 reveal/resolve로 원문 SHA와 quote를 다시 확인한다. 새 Reader가 같은 archive를 열어도 이전 결과를 적용할 수 없다. 원문 bytes가 바뀌면 이전 앵커의 SHA 검증도 거부한다. 원래 EPUB은 쓰지 않고 capture/reveal은 native 읽기 선택만 변경한다. 검색 앵커의 UUID는 임시 결과 identity이며 pendingExcerpt에 넣지 않는다. 기존 발췌 대기 ID·Markdown·노트 CAS·원장·다른 문서·viewport 밖 원문은 수정하지 않는다.

## 한국어 UI와 부모 접합 요구

`VaultEPUBSearchControls(reader:isCurrent:)`는 질의·검색/지우기·완료/초과/오류 상태·장/문단별 결과 미리보기·결과 이동 버튼을 제공한다. 시작/결과 이동은 기존 owner의 isCurrent closure로 검증하고, 종료 시 task/검색 세대를 무효화한다. 기존 `VaultEPUBReaderPanel`에는 같은 controls를 연결했다.

중요: 실제 앱 Workspace는 이 Panel이 아닌 private `VaultEPUBStoreReader`를 소비한다. 이 단위는 사용자 지정 Store/Workspace/Relay 수정0을 유지한다. 따라서 부모 소유 Workspace에서 기존 StoreReader에 순수 읽기 소유권 closure를 전달하고 아래 controls를 넣어야 실제 앱 진입점의 검색 UI 접합이 완료된다. 이 후속 전에는 모듈 Panel/native 구현을 실제 앱 화면 완료로 표시하지 않는다.

```swift
// private VaultEPUBStoreReader의 기존 canAct 옆에 추가
let searchIsCurrent: @MainActor () -> Bool
// 기존 VaultEPUBStoreText(reader:reader) 바로 앞
VaultEPUBSearchControls(reader:reader,isCurrent:searchIsCurrent)
```

기존 StoreReader 호출부에 전달할 값:

```swift
searchIsCurrent: { store.epubIsCurrent(reader) && !store.vaultSaving && !store.hasPendingEPUBExcerpt }
```

정확 위치는 c8992 기준 CanvasWorkspace.swift의 기존 `VaultEPUBStoreReader` 호출과 private 타입 내부다. 기존 canAct Bool을 캡처한 `{ canAct }`만 넘기면 비동기 Task가 시작 시점의 Bool을 보관할 수 있으므로 권고하지 않는다. 기존 Store API를 매번 조회하는 closure를 전달해야 현재 Reader/연결/페이지 소유권을 재평가한다. 새로운 connection/권한/저장 API는 필요 없다. 부모가 새 결합 exact SHA에서 이 UI소유 경계와 SDK를 확인한다. pending 발췌 중 실제 앱 검색 이동은 기존 canAct와 같은 조건으로 제한한다. Reader 공개 API 자체는 pending ID를 바꾸지 않는 읽기 검색을 지원한다.

## 검증

`python3 -B Tests/checks/epub-reader-search/run.py --output <storage-route 승인 경로>`는 자체 고정2장 EPUB/변경 archive를 생성하고 실제 macOS27 NSTextView Reader를 실행한다. 한글/emoji/조합형 한글/NFC·NFD/빈값/불일치/대소문자/정확 UTF16 선택/장간 결과/상한/clear/취소/질의 및 Reader ABA/원문 SHA 변경/발췌 ID 보존/새 Reader를 확인한다. 원본 파일·normal sentinel·소스 전후 SHA도 기록한다. 마지막에 전체 Canvas와 기존 의존성의 iOS27 SDK typecheck를 수행한다. 실제 기기/화면/네트워크/앱 설치/Host/키/권한/알림은 실행하지 않는다. Store/Workspace/Relay는 기준 blob과 동일하게 보존한다. 이전 EPUB 전체 parser/Store/HTTP 검사를 이 새 단위 때문에 반복하지 않는다.

Pstack how/Feature 경로로 Reader source와 UI adapter 소유를 대조하고 Ponytail로 Foundation/capture/reveal/기존 Panel을 재사용했다. ARENA·순정 Goal·새 provider·서비스·상주 loop0이다. 저자 자체 native/SDK 통과를 독립 SOURCE_CLEAR로 대신하지 않으며 부모의 비저자 검수와 UI 접합은 별도다. 원격 push는 부모가 수행한다.
