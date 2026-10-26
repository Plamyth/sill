# PDF 발췌 후보 설계

원담당 지원 작업 `01a17604-c3e8-7373-b2d6-2fee2c3ed5cb`, 작업 키 `pdf-excerpt-source-20261026`.
iPad base `14e941099ca5d27bb4c1df171849d601a14a1455`, relay base `f61f51696aa5cd5b1973277a347ffca3f534fa26`. 전용 외장 worktree만 수정한다.

Pstack Feature/how를 단일 담당 코드 추적으로 적용한다. ARENA·후보 경쟁·중첩 agent는 직접 지시로 생략한다. 독립 검수는 부모가 소유하며 통합·push·설치는 닫혀 있다. Ponytail full에 따라 기존 CanvasStore, VaultNoteRecoveryFile, Markdown CAS, CanvasLocalFile과 PDFKit을 재사용한다. 새 의존성·scene/wire 필드는 없다.

데이터는 읽기 전용 PDF snapshot(path, sha256, dataBase64), Markdown 본문 안의 version 1 PDF provenance, 기존 .md VaultNoteReference다. UUID excerptID는 CCR에서 직접 선택한 발췌 식별자이고 원앱 nativeID가 아니다. nativeID는 생성하지 않는다. Markdown은 사람이 읽는 PDF 페이지 링크, 원문 quote, 편집 가능한 메모와 엄격한 JSON fence를 갖는다. PDFKit page space rect, MediaBox, CropBox, rotation, PDF SHA를 검증한다. 이 후보는 회전 0만 허용하고 회전 일반화를 주장하지 않는다.

PDF bytes는 기존 인증 relay에서만 읽으며 외부 모델·신규 서버로 전송하지 않는다. relay는 PDF 전용 GET과 entry kind만 추가하고 note PUT은 .md 전용이다. 크기 제한은 20 MiB이며 파일 descriptor 기반 제한 읽기와 PDF magic을 확인한다. 경로 구성요소·확장자·심볼릭 링크를 경계에서 거부한다.

생성은 기존 로컬 노트 복구 원장에 create-only 의도를 먼저 보존하고 같은 UUID의 .md 경로에 CAS(null)로 수행한다. 응답과 별도 GET의 정확한 bytes를 모두 확인한 뒤 기존 노트 attach를 재사용한다. 재열기/응답 상실에서는 같은 path만 확인하며 다른 UUID나 자동 재전송을 만들지 않는다. 원문 변경/삭제에서는 changed/missing을 표시하고 scene cache를 보존한다.

처리량 체크포인트.
- Blocking first steps. 기준 HEAD/clean 상태·원본 SHA·기존 API와 복구 계약을 먼저 확인한다.
- Independent workstreams. relay 경계와 Swift 모델/UI 구현은 파일이 분리되며 독립 검사 호출을 병렬 수행한다.
- Shared mutable state. 두 정본·실사용 vault·Host·UI·오디오·8791/8793에는 접근하지 않는다. 소유 WT만 쓴다.
- Smallest safe decomposition. 단일 발췌 왕복이므로 이 담당이 구현하고 부모가 독립 검수한다. 중첩 agent는 금지다.

Apple 공식 문서 https://developer.apple.com/documentation/pdfkit/pdfselection/bounds(for:) 는 page space bounds를, https://developer.apple.com/documentation/pdfkit/pdfselection/selectionsbyline() 는 줄별 선택을 제공한다. 실제 SDK 선언과 컴파일을 함께 확인한다. REA 자료는 단일 자체 PDF의 native rect가 Core를 선택한 근거이며 제품 동등성·회전 일반화·실제 Pencil 수용 근거가 아니다. 원본 7개는 전후 SHA로 보존 확인한다.

## 실제 코드 연결

`CanvasWorkspace.vaultSheet`의 기존 목록에서 PDF entry를 연다. `CanvasRelay.vaultPDF`는 기존 인증만 사용하며 PDF bytes와 JSON 응답 크기를 제한한다. `VaultPDFReader`의 PDFKit 선택에서 `VaultPDFExcerpt`를 만든다. 발췌 Markdown은 PDF가 있던 폴더의 `발췌-<excerptID>.md`다. 텍스트가 없는 스캔 PDF와 여러 페이지에 걸친 선택, 회전된 PDF는 이 후보에서 발췌하지 않는다.

`CanvasStore.preparePDFExcerpt`는 전용 `VaultPDFCreateRecoveryFile`과 `CanvasPDFExcerptCreate/recovery.json`에 create-only 의도를 보존한다. 일반 노트의 `VaultNoteRecovery`와 공통 v1 파일은 기존 형태를 유지한다. 구소비자는 전용 파일을 조회하지 않으며 전용 envelope는 일반 노트 복구 타입으로 decode되지 않는다. 새 StateFile은 기존 CanvasRuntime의 격리 경로·안전한 파일 쓰기·상태 루트 정리 경계를 사용한다. scene, node, Host wire에는 새 필드를 넣지 않는다. scene과 생성 journal의 저장 및 필요한 블록 닫기 검사가 성공한 뒤 기존 에디터 메모리를 초기화한다. 블록 닫기 실패 시 소유 생성 의도를 취소하고 열린 원문·입력 세대·선택을 유지한다. `savePDFExcerpt`는 기존 .md CAS(null)를 사용하며 정확한 GET 이후 `attachOpenedVaultNote`로 연결한다. 결과가 불명확한 재열기는 같은 path의 GET만 수행한다. 사용자가 같은 ID의 저장 재확인을 명시적으로 누른 경우에만 GET 404 뒤 같은 path의 CAS(null)를 허용한다.

Markdown 편집·초안 보존·CAS 충돌·카드 캐시 역수신은 기존 노트 흐름을 사용한다. 발췌 JSON의 quote는 선택 당시 원문이다. 메모 편집이 quote나 출처를 자동 재작성하지 않는다. Markdown 본문을 바꾼 사람이 JSON까지 바꾸면 신뢰 경계의 형식·페이지·해시·좌표·quote 검증을 다시 거친다. 출처 JSON 뒤에 메모를 덧붙여도 출처를 읽을 수 있다.

`sourcePage`는 PDF SHA와 페이지 MediaBox/CropBox/rotation을 검증한다. 새 schema2 provenance는 PDFSelection.numberOfTextRanges(on:)와 range(at:on:)가 반환한 NSRange를 저장하고 같은 PDF의 PDFPage.selection(for:NSRange)로 복원한다. characterBounds의 glyph 인덱스로 변환하지 않는다. 복원한 실제 범위·줄별 page-space rect·quote의 UTF-8 bytes를 모두 확인한다. capture는 같은 bytes의 원문 복귀를 확인한 선택만 반환한다. 기존 schema1 geometry-only 후보와 자체 REA native rect는 기존 rect 선택 경로로 읽는다. 다른 해시는 changed, 없는 파일은 missing 안내를 표시한다. .md를 가리키는 기존 참조의 의미를 PDF 참조로 바꾸지 않는다. PDFView는 외부 PDF action과 URL 링크를 실행하지 않고 로컬 페이지 이동만 허용한다. PDF 원본 저장 API나 PDF 재직렬화는 없다.

## 검증과 검수 경계

`tests/checks/linked-obsidian-notes/run.py`는 `PENCIL_RELAY_REPO`로 전용 relay WT를 선택한다. `PENCIL_REMOTE_FIXTURE=1`과 `--vault-roundtrip`을 주면 Mini의 작업별 한시 소스 안에서 실제 ObsidianVault fixture를 실행한다. Swift와 Node는 표준입출력으로 통신하며 웹 서버·소켓 listener를 만들지 않는다. 이 경로에 필요한 Node는 Mini의 기존 `/Users/sin-wonho/.local/bin/node`다. `PENCIL_REA_FIXTURE`를 지정하면 원래 자체 PDF의 native rect 대조만 맥북에서 읽기 전용으로 실행한다. 원본 PDF나 archive는 Mini로 전송하지 않는다.

초기 기존 relay 회귀 검사 48개에는 Mini 임시 loopback listener를 여는 기존 HTTP fixture가 포함됐다. 엄격한 포트 금지 범위와 달라 후속 최종 검사는 `tests/no-network-listeners.cjs`로 listen 자체를 차단한다. HTTP 경계는 서버 request handler를 소켓 없이 호출한다. 기존 HTTP fixture 2개는 `--test-skip-pattern=authenticated .*HTTP`로 제외한다. 초기 fixture는 검사 종료로 닫혔으며 기존 서비스 재시작과 8791/8793 접속은 없다.

이 후보에는 iPad 실물 UI, Pencil 입력, Host·오디오 조작, 서명·설치·push·통합·유료 CI·실사용 vault 쓰기 증거가 없다. 독립 검수는 부모 담당이 정확한 두 후보 commit에서 수행한다. REA 기능 근거, 소스 검사, SDK 타입 검사, 실물 수용은 별개다. 제품 동등성이나 전체 복각 완료를 주장하지 않는다.

실행 결과는 외장 작업 루트의 `final-transport/result.json`, `final-roundtrip/result.json`, `relay-final-path-identity.log`, `originals-preservation.json`에 남긴다. 최종 기본 회귀와 PDF 전송 URLProtocol 검사는 385 assertions, 파일 왕복과 실제 native PDF 대조는 111 assertions로 모두 실패 0이다. 각 Swift 검사에서 macOS 컴파일과 iOS SDK 타입 검사 exit 0 및 검사 입력 SHA 불변을 확인했다. 최종 relay 검사는 포트 바인딩 차단 아래 20개가 통과했다. Mini 한시 소스 삭제는 각 실행의 `cleanup_verified=true` 영수증으로 확인한다. 기존 두 iOS SDK deprecated 경고는 이 후보 변경 밖이다.

## 2026-10-26 미발행 후보 회귀 수리

검수 기준은 iPad 943d3869d48d725a6b03b1aad78fd37853675270과 읽기 전용 relay 2250dfada987013e6fc09e40e8bf2a58db134245다. 공통 복구 파일의 optional create flag는 제거했다. 이전 후보는 정본·실사용 파일에 발행되지 않았으므로 해당 잘못된 공통 journal을 자동 이관하지 않는다. 일반 노트 복구 데이터와 새 생성 의도를 섞지 않는다.

사람용 quote는 줄마다 blockquote를 만들고 ASCII 구두점·공백을 숫자 문자 엔티티로 인코딩한다. JSON quote는 원래 bytes를 유지한다. parser는 행 시작의 실제 provenance fence만 세며 평문 marker를 구문으로 취급하지 않는다. 중복·지원 외 버전·알 수 없는 필드는 거부한다. 메모는 기존처럼 편집할 수 있다. 실제 Obsidian renderer와 외부 효과는 실행하지 않았다.

PDF loading은 별도 Boolean 없이 요청 ID의 존재로 계산한다. 목록·닫기·연결·장면 전환은 ID를 비우며 늦은 성공·실패는 같은 요청·연결·장면·열린 노트일 때만 반영한다. 제품 메서드와 목록 action의 추출 실행은 가능하나 실제 SwiftUI·Pencil·설치67/68 수용과는 구분한다.

수리 검사는 `Tests/checks/linked-obsidian-notes/run.py <외장 출력> --pdf-recovery`로 실행한다. `PDF_RECOVERY_FIXTURE`에는 독립 검수의 `probe2/unicode-selection.pdf`, `PDF_RECOVERY_RETAINED`에는 기존 자체 REA PDF의 절대 경로를 준다. 기본385·왕복111 검사와 같은 runner이며 `--vault-roundtrip`에서는 기존 Mini 한시 소스와 listen 금지 guard를 사용한다. `pdf-loading-check.py <외장 출력> [기준 CanvasWorkspace.swift]`는 제품 메서드·목록 action·상태 선언을 그대로 추출해 지연 응답을 검사하고 source SHA를 남긴다. `Tests/checks/ipad-test-context/run.py`는 DEBUG/Release 격리 경로와 새 StateFile의 symlink·hardlink·override 경계를 검사한다. 모든 출력은 이 작업의 외장 전용 경로에 남긴다.

이 수리는 현재 제품68에 미적용이다. push·통합·설치·Host·UI·오디오·실 vault·공유 포트 변경은 수행하지 않는다. 회전·다중 페이지 선택은 기존 제한을 유지한다. 새 고정 HEAD의 최종 독립 재검수는 부모 담당에게 맡긴다.

최상위 PDF 출처 블록은 Foundation의 Markdown presentationIntent와 markdownSourcePosition으로 식별한다. HTML 주석·인용·목록·상위 코드 예제를 자체 fence 상태기로 추정하지 않는다. 실제 최상위 codeBlock에서만 원래 canonical fence와 버전·크기·JSON·좌표·NSRange 검증을 계속 적용한다. 인용문은 첫 들여쓰기 문자만 필요에 따라 entity로 표현해 공백·탭과 기호를 실제 화면에서 literal로 보존한다. JSON의 원문 quote는 변경하지 않는다. 이 경로는 iOS16 이상 API이며 현재 앱의 iOS17 이상 대상 안에 있다.

## 빈 Markdown 출처 블록의 검증

Foundation은 빈 코드 블록을 attributed run에서 생략한다. 파싱용 사본의 잠재 출처 시작 행 다음에 고정 본문을 넣어 빈 블록도 문맥 분류에 포함한다. 실제 최상위 canonical 블록의 두 번째 줄만 제거한 뒤 원래 JSON을 검증하며 사본은 저장·표시하지 않는다. 빈 블록, 미래 버전, 닫히지 않은 블록과 중복 출처는 거부하고 HTML 주석·바깥 코드 예제 안의 블록은 자료로 유지한다. 경계 검사 126개와 iOS SDK 검사가 통과했다. 실제 iPad·Pencil 및 사용자 보관함 검증은 별도 미완료다.
