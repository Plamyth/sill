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

`CanvasStore.preparePDFExcerpt`는 기존 로컬 `VaultNoteRecoveryFile`에 create-only 의도를 보존한다. `createPDFExcerpt`는 이 기기의 복구 파일에만 있는 선택 필드다. scene, node, Host wire에는 넣지 않는다. `savePDFExcerpt`는 기존 .md CAS(null)를 사용하며 정확한 GET 이후 `attachOpenedVaultNote`로 연결한다. 결과가 불명확한 재열기는 같은 path의 GET만 수행한다. 사용자가 같은 ID의 저장 재확인을 명시적으로 누른 경우에만 GET 404 뒤 같은 path의 CAS(null)를 허용한다.

Markdown 편집·초안 보존·CAS 충돌·카드 캐시 역수신은 기존 노트 흐름을 사용한다. 발췌 JSON의 quote는 선택 당시 원문이다. 메모 편집이 quote나 출처를 자동 재작성하지 않는다. Markdown 본문을 바꾼 사람이 JSON까지 바꾸면 신뢰 경계의 형식·페이지·해시·좌표·quote 검증을 다시 거친다. 출처 JSON 뒤에 메모를 덧붙여도 출처를 읽을 수 있다.

`sourcePage`는 PDF SHA와 페이지 MediaBox/CropBox/rotation 및 실제 rect 선택 텍스트를 확인한 후에만 위치를 연다. 다른 해시는 changed, 없는 파일은 missing 안내를 표시한다. .md를 가리키는 기존 참조의 의미를 PDF 참조로 바꾸지 않는다. PDFView는 외부 PDF action과 URL 링크를 실행하지 않고 로컬 페이지 이동만 허용한다. PDF 원본 저장 API나 PDF 재직렬화는 없다.

## 검증과 검수 경계

`tests/checks/linked-obsidian-notes/run.py`는 `PENCIL_RELAY_REPO`로 전용 relay WT를 선택한다. `PENCIL_REMOTE_FIXTURE=1`과 `--vault-roundtrip`을 주면 Mini의 작업별 한시 소스 안에서 실제 ObsidianVault fixture를 실행한다. Swift와 Node는 표준입출력으로 통신하며 웹 서버·소켓 listener를 만들지 않는다. 이 경로에 필요한 Node는 Mini의 기존 `/Users/sin-wonho/.local/bin/node`다. `PENCIL_REA_FIXTURE`를 지정하면 원래 자체 PDF의 native rect 대조만 맥북에서 읽기 전용으로 실행한다. 원본 PDF나 archive는 Mini로 전송하지 않는다.

초기 기존 relay 회귀 검사 48개에는 Mini 임시 loopback listener를 여는 기존 HTTP fixture가 포함됐다. 엄격한 포트 금지 범위와 달라 후속 최종 검사는 `tests/no-network-listeners.cjs`로 listen 자체를 차단한다. HTTP 경계는 서버 request handler를 소켓 없이 호출한다. 기존 HTTP fixture 2개는 `--test-skip-pattern=authenticated .*HTTP`로 제외한다. 초기 fixture는 검사 종료로 닫혔으며 기존 서비스 재시작과 8791/8793 접속은 없다.

이 후보에는 iPad 실물 UI, Pencil 입력, Host·오디오 조작, 서명·설치·push·통합·유료 CI·실사용 vault 쓰기 증거가 없다. 독립 검수는 부모 담당이 정확한 두 후보 commit에서 수행한다. REA 기능 근거, 소스 검사, SDK 타입 검사, 실물 수용은 별개다. 제품 동등성이나 전체 복각 완료를 주장하지 않는다.

실행 결과는 외장 작업 루트의 `final-transport/result.json`, `final-roundtrip/result.json`, `relay-final-path-identity.log`, `originals-preservation.json`에 남긴다. 최종 기본 회귀와 PDF 전송 URLProtocol 검사는 385 assertions, 파일 왕복과 실제 native PDF 대조는 111 assertions로 모두 실패 0이다. 각 Swift 검사에서 macOS 컴파일과 iOS SDK 타입 검사 exit 0 및 검사 입력 SHA 불변을 확인했다. 최종 relay 검사는 포트 바인딩 차단 아래 20개가 통과했다. Mini 한시 소스 삭제는 각 실행의 `cleanup_verified=true` 영수증으로 확인한다. 기존 두 iOS SDK deprecated 경고는 이 후보 변경 밖이다.
