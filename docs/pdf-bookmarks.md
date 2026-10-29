# PDF 물리 페이지 책갈피

기준은 공식 `cd5e79105904e25438c50a53b845c2d17a2b6b3e` / tree `5741ea4adac55e33b951c160462be7aaede4021b`다. 작업은 `codex/ipad-pdf-bookmarks-20261029`의 전용 `pdf-bookmarks-20261029/source`에서 수행한다. EPUB·Store·Workspace·Relay·PencilCanvas·Host·원래 그룹 브랜치는 수정하지 않는다.

## 근거와 사용자 행동

385항목 원장의 MM11.03, R049 `margin-multipage-observed-spec.md`에 결속한다. Mac MarginNote 4.4.6의 자체 3쪽 PDF에서 3쪽 책갈피 생성 → 1쪽 이동 → 책갈피로 3쪽 복귀 → 탭 재열기 유지를 관측했다. 실제 저장 필드, 앱 cold restart, iPad/Pencil 동등성은 이 근거로 확인하지 않았다. CCR의 별도 프로세스 저장·재열기 검사는 CCR 구현의 근거이며 원앱의 미관측 동작으로 바꾸지 않는다.

기존 PDF 보기 설정 UI에 ‘현재 쪽 책갈피 추가’, 물리 원문 쪽·책갈피 유무, ‘책갈피 목록’, 원문 쪽 이동·명시 제거를 붙였다. 추가·제거는 기존 보기 초안이며 기존 Undo/Redo·‘보기 설정 Markdown 저장’으로 확정한다. 목록 이동은 기존 `go(toPageNumber:)`를 사용한다. 표시 순서의 위치를 책갈피 번호로 저장하지 않는다. 내장 PDF 목차와도 별개다. 사용자 지정 책갈피 제목·미리보기 이미지·현재 페이지의 자동 저장은 이번 범위가 아니다.

## 같은 Markdown과 엄격한 v1/v2

기존 `PDF보기-<PDF SHA256>-<UTF8 경로 SHA256>.md` 파일과 원문 path/SHA/페이지 수 결속을 그대로 사용한다. 새 DB·별도 책갈피 파일·서버 API·scene wire는 없다. 추가한 상태는 기존 `VaultPDFViewState.bookmarks: [Int]`뿐이며 각 값은 1기반 물리 페이지다. 배열 순서는 명시 추가 또는 외부 Markdown에 적은 순서다. 유일하고 유효한 페이지 번호만 허용한다.

- 책갈피가 없으면 기존 v1 바이트 형식을 기록한다. 기존 v1 Markdown을 읽으면 빈 배열이다. v1 본문에 책갈피 줄을 임의 추가한 혼합 형식은 거부한다.
- 책갈피가 있으면 첫 marker만 `<!-- ccr:pdf-view-state:v2 -->`로 바꾸고 ‘표시 순서’ 다음 줄에 `책갈피: 3, 1`을 넣는다. 나머지 path/SHA/쪽 수/순서/crop 표 계약은 v1과 같다. 최소 한 개의 번호가 필요하다. 중복 줄·중복 번호·범위 밖·빈 줄 값·임의 추가 본문·미지원 marker는 거부한다.
- 마지막 책갈피를 명시 제거하면 지원되는 빈 상태인 v1로 저장한다. 읽지 못한 문서를 v1로 fallback하거나 덮지 않는다. 외부 원문 채택도 기존 비교·명시 선택을 거친다.
- Codable recovery의 기존 키는 유지하고 `bookmarks` 키만 추가했다. 키가 없는 옛 저장본은 빈 배열로 읽는다. 명시 null은 오류다. 기존 SaveRequest의 Markdown과 state 대조·복구 validation을 그대로 사용한다. 새 책갈피가 있는 요청을 옛 reader로 읽으면 v2 Markdown/옛 state 재직렬화가 맞지 않아 거부한다. v1 Markdown·옛 Codable 요청은 정확 cd5 codec으로 생성해 검사한다.

## 제품 접합과 보호

Reader의 `setBookmark(_:physicalPageNumber:)`는 현재 보기 상태를 검증하고 기존 `applyViewState`로만 변경한다. 중복 추가·없는 번호 제거는 no-op이고 범위 밖 번호는 거부한다. 원문 PDF 바이트·회전·물리 쪽·기존 발췌 textRanges와 인용문은 쓰지 않는다. 순서·crop과 함께 같은 보기 초안으로 보존하며 선택도 기존 원문 대조를 통해 유지한다.

Store/Workspace의 PDF 전용 접합은 이미 Reader를 관찰하며 변경 시 `preservePDFViewDraft`를 호출한다. 기존 `pdfViewCanEdit/pdfViewCanPersist`, ViewRequest UUID·연결 generation·PageSnapshot·Reader identity, 명시 CAS PUT + 전체 GET, ACK 미확인 복구 파일과 conflict 원장을 그대로 소비한다. 이 때문에 공유 Store/Workspace 변경이 필요하지 않았다. EPUB 소유 코드와 새로운 공통 계약 충돌은 없다. 정상 파일·사용자 vault·GUI·기기·설치·공유 서비스는 변경하지 않는다.

## 좁은 검증과 재사용

`python3 Tests/checks/pdf-view-product/run.py --bookmarks --output <storage-route 승인 출력>`은 기존 실행기의 PDFKit·전체 Document Files·격리 `--ccr-test-runtime`·실제 ObsidianVault stdio 파일 CAS를 재사용하며 새 책갈피 검사만 실행한다. 기존 전체 Store/385 검사로 확장하지 않는다. `git show cd5...:iOSClient/CanvasBridge/VaultPDFViewState.swift`의 정확 바이트를 읽어 Swift 타입 이름만 바꿔 같은 실행 파일에서 옛 codec을 실행한다. 입력 SHA와 변환을 출력 영수증에 남긴다. 기존 자료를 편집해 과거 형식이라고 꾸미지 않는다.

새 검사는 v1/v2·옛 Codable recovery, 실제 3쪽/회전 PDF의 선택·물리 복귀·Undo, 실제 Files와 sidecar 저장·새 Store/새 프로세스 재열기, 외부 Markdown 역수신·손상 거부·CAS 409·명시 비교/채택, ACK 유실 뒤 GET만 확인, 저장 중 새 입력·연결 ABA/늦은 저장 callback의 원장 보존, PDF/발췌/원래 카드/전체 Document 불변을 다룬다. GUI 대신 실제 UI 소스의 callback·보호 binding과 iOS SDK typecheck를 대조한다. 실제 UI 손조작 수용으로 표시하지 않는다.

Pstack Feature/how 경로로 기존 subsystem과 신뢰 경계를 확인했다. 선행 차단 항목은 exact base·clean WT·storage-route다. 독립 입력 조사/SDK 검사는 병렬이며 codec–Reader–복구 검사는 같은 기능 소유자가 담당한다. 공유 가변 상태는 별도 WT로 분리했고 최소 분해 단위는 기존 SaveRequest 하나다. Ponytail은 기존 state/controls/Undo/CAS 재사용에 적용했다. ARENA·순정 Goal·중첩 worker·상주 loop는 사용하지 않는다. 독립 소스 검수와 공식 반영은 부모에게 정확 commit/tree와 영수증으로 넘기며 이 writer 검사로 대체하지 않는다.

실제 writer 결과는 새 책갈피 본 검사 55건, 별도 프로세스 재열기 3회(자식 프로세스 확인 9건), 실제 UI 소스 연결 대조 8건 통과다. iOS 27 전체 Canvas 소스 및 기존 의존 입력 29파일의 SDK typecheck가 통과했다. 전체 앱 번들 빌드·xrOS SDK·GUI·iPad·HTTP socket 검사는 실행하지 않았다. Obsidian 파일 검사는 실제 공식 모듈의 stdio 호출이며 HTTP 응답을 가장하지 않는다. 5개 atomic helper의 종료와 normal 보호 파일·검사 입력 SHA 불변을 확인했다. 기존 전체 385·147·Store 회귀는 반복하지 않았다.

초기 검사 코드의 async autoclosure 컴파일 오류를 수정했고, Files 준비 단계에서 경로의 `BT_CCR-ipad`와 실제 파일시스템 `BT_CCR-iPad`의 차이를 Foundation으로 재현했다. fixture에 기존 실행기와 같은 `resolvingSymlinksInPath`를 적용한 뒤 통과했다. Files 원문 접근 guard·권한은 수정하지 않았으며 실패 출력도 전용 evidence에 보존했다. 성공 검사와 SDK의 소스 해시를 최종 커밋 파일과 다시 대조하며 이후 전체 재실행으로 대체하지 않는다.
