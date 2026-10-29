# PDF 표시 순서·자르기와 원본 앵커 분리

기준은 공식6643098adbb02299fc9d23e0069cb5905c984970/tree43fa2a0e14a5e0fc16361ca30ea3e90481033148다. codex/ipad-pdf-view-state-20261029의 전용 pdf-view-state-20261029/source에서만 변경한다. 원래 PDF900/목차ea0/docs2319 계보는 유지한다.

## 근거와 구현 단위

margin-pdf-order-observed-spec.md는 MarginNote Mac4.4.6의 자체3쪽 PDF에서 표시 순서2-1-3과 원래1쪽의 발췌·목차 복귀, 같은 프로세스 스터디 재열기를 관측했다. 일반 Undo/Redo는 그 순서를 복구하지 않았고 명시 Up으로 복구했다. margin-pdf-crop-edit-observed-spec.md는 오른쪽 crop 비율0.94181034482758619, 실제 Undo→전체보기/Redo→crop, 직접 원복·스터디 재열기를 관측했다. 기존19개 노트·6개 미디어·5개 원문은 비교 범위에서 유지됐고 전체 메타데이터 바이트 동일성이나 iPad/실제 Pencil/cold restart 수용은 아니다.

이 구현은 기존 원문 PDFDocument와 물리 페이지 identity를 그대로 두고 표시용 PDFDocument에 순서/crop을 투영한다. 새 발췌는 표시 페이지의 UTF16 범위를 원래 물리 페이지로 대조해 기존 VaultPDFExcerpt.capture/sourcePage를 사용한다. 기존 발췌의 PDF SHA/물리 pageIndex/MediaBox/CropBox/rotation/quote/범위는 수정하지 않는다. 표시 위치와 원문 쪽을 별도 표시하고, 목차는 물리 목적 쪽을 현재 표시 위치에서 찾는다.

crop은 원본 PDFKit CropBox의 페이지 좌표에서 x/y/width/height를0~1 비율로 표현한다. 화면의 위/아래 좌표로 추측하거나 y축 반전·보기 회전 metadata를 추가하지 않는다. 빈/음수/비유한/범위 밖 crop, 페이지 누락·중복·다른 PDF identity는 적용 전에 거부한다. crop으로 기존 인용이 가려지면 그 물리 쪽만 임시 전체보기로 열어 원문을 확인한다. 저장 crop은 그대로이고 다음 유효 페이지 이동에서 원래 표시 설정으로 돌아온다. 거부된 이동은 선택과 임시보기도 유지한다.

Reader 안의 보기 전용 Undo/Redo는 최근32개 메타데이터 편집에 한정한다. 원본 PDF/잉크·문서 전체/기존 Store의 Undo 원장은 쓰지 않는다. crop Undo/Redo는 실제 REA 근거와 대조한다. 이 보기 전용 명령이 순서도 되돌리는 것은 CCR의 명시 계약이며 원앱 일반 Undo가 순서를 복구했다는 주장으로 바꾸지 않는다.

## 사람이 읽고 AI가 수정하는 Markdown

별도 일반 note 경로는 `<원본 PDF의 기존 폴더>/PDF보기-<PDF SHA256>-<UTF8 경로 SHA256>.md`다. 같은 PDF 바이트가 다른 경로에 있어도 서로의 설정 파일을 덮지 않는다. 이미 존재하는 PDF 폴더를 재사용하므로 별도 폴더 생성 API가 필요하지 않다. 기존 note GET/PUT 이외의 서버 API·provider·DB·scene kind는 없다. Markdown 예시는 다음과 같다.

```markdown
<!-- ccr:pdf-view-state:v1 -->
# PDF 보기 설정

PDF 경로: 문서/원본.pdf
PDF SHA256: <실제64자리 SHA256>
물리 페이지 수: 3
표시 순서: 2, 1, 3

| 원문 쪽 | x | y | width | height |
| --- | --- | --- | --- | --- |
| 1 | 0.0 | 0.0 | 0.9418103448275862 | 1.0 |
| 2 | 0.0 | 0.0 | 1.0 | 1.0 |
| 3 | 0.0 | 0.0 | 1.0 | 1.0 |
```

번호는 사람이 읽는1기반 물리 쪽이다. 순서는 모든 물리 페이지의 정확한 순열이며 표도 원문 쪽 순서대로 모든 페이지를 한 번씩 포함한다. 이 v1 형식의 LF/CRLF 입력을 읽으며 순서 배열·숫자·표는 직접 수정할 수 있다. 알 수 없는 버전/추가 임의 본문/누락·중복 행/다른 SHA는 거부하며 일반 노트나 과거 형식으로 fallback하지 않는다. 지원하지 않는 파일을 정규화해 덮지 않는다.

## 부모 Store/Workspace 최종 접합 계약

이 단위는 Store/Workspace/Relay를 수정하지 않았다. Reader의 편집/표시 API와 독립 `VaultPDFViewStateControls`만 제공한다. 정상 UI에 sidecar 로드/저장을 연결하는 것은 이 파일의 callback 계약을 부모/Helm이 기존 입력 epoch·noteRecovery·conflict barrier에 접합한 뒤 수용해야 한다. 코드·네이티브/파일 검사를 전체 제품 UI 완료로 표시하지 않는다.

1. 기존 인증된 PDF GET의 snapshot과 note GET을 사용한다. `VaultPDFViewState(snapshot:pageCount:)`의 notePath로 전체 MD를 조회한다. 명시404일 때만 새 기본 보기 생성을 허용한다. typed409/권한/IO/파싱 실패를 nil로 바꿔 default state를 여는 fallback은 금지한다. 기존 Reader·입력·복구 자료를 보존한다.
2. `VaultPDFViewState.parse(text,snapshot:pageCount:)` 후 `VaultPDFReader(snapshot:source:viewState:)`로 재열거나 `reader.applyViewStateNote(note)`로 외부 MD를 적용한다. 후자는 local draft가 dirty면 거부한다. 외부 conflict 선택 뒤 교체할 때에는 기존 Store의 명시 선택·epoch 보호를 마친 새 Reader를 만든다. PDF 경로는 UTF8 바이트로 결속한다.
3. `moveDisplayPage(from:to:)`, `setCrop(_:physicalPageNumber:)`, `undoViewState`, `redoViewState`, `applyViewState`는 보기 초안만 바꾼다. `pageNumber/pageIndex`는 계속 원문 물리 쪽이고 `displayPageNumber`, `go(toDisplayPageNumber:)`는 표시 위치다. `go(toPageNumber:)`와 목차·`returnToSource`는 물리 쪽 identity를 유지한다.
4. `VaultPDFViewStateControls(reader:base:canEdit:canPersist:onSave:onReload:)`의 canEdit/canPersist는 부모의 실제 입력·미확인 저장·conflict barrier에 결속한다. base=nil은 명시404가 확인된 때만 준다. 이미 존재하는 note를 새 note로 취급하지 않는다. onSave는 불변 SaveRequest(path/baseSHA256/markdown/state)를 받는다. **PUT 전에 기존 durable note 저장 의도 원장에 동일 path/base/text를 보존**한다. 새 별도 recovery DB는 만들지 않는다. Reader도 base의 파싱된 상태가 자신이 로드/확인한 저장 기준과 같은지 검사하므로, dirty 초안에 다른 외부 상태를 새 CAS 기준으로 끼워 넣지 못한다. 이미 로드한 sidecar는 base=nil 생성 모드로 전환할 수 없다.
5. 원장 보존/소유권 gate 후 `request.submit(save:load:)`에 기존 note PUT/GET callback을 전달한다. save 서명은 `(path:String, baseSHA256:String?, text:String) async throws -> VaultNoteSnapshot`, load는 `(path:String) async throws -> VaultNoteSnapshot`이다. 한 번의 명시 PUT과 일치하는 전체 GET만 완료로 확인한다. 에러는 그대로 반환하고 자동 재시도·형식 전환·새 ID를 만들지 않는다.
6. 양쪽 확인 후 기존 epoch/Reader identity를 검증하고 `reader.confirmViewStateSave(request,note:)`로 기준만 갱신한다. 저장 중 더 새 입력이 있으면 초안은 남고 hasViewEdits=true다. callback 결과로 새 초안을 덮지 않는다. Store는 기존 원장의 정확한 입력/확인값만 해제한다.
7. PUT 응답 유실이면 같은 SaveRequest와 durable path/base/text를 보존한다. 명시 GET 결과를 `request.confirmed(note)`로 대조해 확인하며 두 번째 PUT을 자동 전송하지 않는다. typed409/held면 기존 conflict 계약의 원문 대조·명시 복구까지 막는다. 복구를 우회하는 별도 resolver를 추가하지 않았다.

## 검사 범위

기존 linked-obsidian-notes 실행기를 확장해 --pdf-view-state(native/codec), --pdf-view-state-files(실제 ObsidianVault 파일 note CAS/GET), --pdf-view-state-reopen(새 Swift 프로세스)을 분리한다. 실제 PDFKit으로0/90/180/270도·음수 원점/CropBox·선택 범위·기존 발췌/목차를 대조하고 상태 Markdown/PDF/기존 source note의 실제 파일 재열기를 검사한다. 지원 밖 상태·외부 CAS·응답 유실·typed409·늦은 응답에서 입력과 원본을 보존한다. Files phase는 기존 mini-ephemeral-source와 격리 stdio backend를 재사용하며 listener0이다.

새 codec을 기존 iOS Sill/SillPhone 두 대상의 Sources에 등록하고 관련 SDK typecheck를 수행한다. UI 손조작·Window 생성·기기·Host·설치·실 vault·질문·알림은 수면 Sentinel 경계로 실행하지 않는다. 원앱 Mac 관측을 iPad 실물 수용으로 확대하지 않는다. 기존 전체385/43/191 및 서버13검사를 반복하지 않는다. 정확한 결과/해시·소유 범위·실패와 수리는 전용 evidence 영수증으로 반환한다.

## Store·Workspace 제품 접합 (Helm)

별도 `pdf-view-product-20261029/source`에서 df4eab84를 기준으로 e09486a8/c2118385를 소비하고 f09daa17을 의미 병합했다. `CanvasStore` 상단 잉크 Undo/tool owner, `CanvasDocument`의 activation 및 `PencilCanvas`는 f09 바이트를 그대로 보존한다. Pstack의 기존 경로 대조와 경계 중심 구현, Ponytail의 기존 note API·기록 파일 재사용을 적용했다. 새 네트워크 API·DB·원본 복사 계층은 없다.

- 기존 PDF 보기 메뉴가 Store 소유 Reader와 표시 순서·crop·보기 Undo/Redo·저장/재조회 UI를 사용한다. 원문 PDF는 쓰지 않으며 sidecar는 같은 폴더의 일반 Markdown이다. 명시 404만 새 보기 기준으로 인정한다. 기존 note 편집·발췌 카드와 전체 Document Files 원본을 동일 기능으로 합치지 않는다.
- 기존 `CanvasPDFExcerptCreate/recovery.json`에 선택적인 `viewRecovery`를 넣어 원래 base, 최신 draft, 불변 submitted 및 작업 ID를 보존한다. 기존 발췌 payload와 상호 오해하지 않는다. 옛 reader가 이 새 payload를 읽으면 발췌 형식 검증에서 거부해 원본을 보존한다. 이 로컬 복구 확장은 기존 scene/Document/server wire를 바꾸지 않는다.
- PUT보다 먼저 실제 복구 파일을 기록한다. 제출과 전체 GET이 같고 문서 snapshot·연결 세대·Reader identity가 그대로일 때만 확인한다. 저장 중 새 입력은 새 기준 위 초안으로 남는다. 응답 유실은 명시 GET만 허용하고, typed 또는 unclassified409는 SHA만으로 해제하지 않는다.
- 보존 충돌은 기존 `/vault/note/conflict` 비교·선택 계약을 소비한다. `NoteConflictChoice.json`과 기존 정확 UUID형 `NoteConflictAttempt-*`에 이전 전체 입력과 후보를 보존하고 선택 자료를 PDF 상태로 검증한 뒤 기존 resolve/GET을 사용한다. 미지원 후보·역수신·IO·늦은 callback은 원본을 교체하지 않는다.
- 서버 conflict GET의 명시 404 **뒤** 현재 note 전체 GET이 비보존 상태이며 PDF identity/형식 검증을 통과한 경우에만 일반 CAS 비교 후보를 만든다. 사용자가 현재 원문 채택을 누르면 전체 GET을 다시 대조하고 옛 base/draft/submitted를 보존한 채 로컬 보기를 연다. PUT 재시도·원문 덮어쓰기·서버 충돌 해제 추정은 없다. 비교 뒤 외부 원문이 바뀌면 다시 거부한다.
- 미기록 Reader 초안·기록 IO 실패·미확인 제출·숨은 비교 파일은 원본/페이지 교체 gate에 포함된다. 연결이 바뀌어도 기록 실패한 Reader는 메모리에 남기고 이전 provider의 action/callback은 차단한다. 완료된 PDF 비교는 일반 노트 편집의 기존 비교 슬롯에 넘기기 전에 전체 보존본을 기존 attempt 파일로 남긴다. 사용자 복구 자료를 삭제하거나 GC하지 않는다.

`Tests/checks/pdf-view-product/run.py --output <승인된 외장 출력 폴더>`는 실제 macOS SDK/PDFKit·CanvasLocalFile·전체 Document Files·공식 ObsidianVault 파일 모듈을 격리 stdio로 연결한다. 자체 3쪽 PDF/발췌를 만들고 별도 프로세스 재열기, 외부 Markdown 역수신, 원자 교환 후 충돌, 응답 유실, 명시 복구, 원래 PDF/발췌 Markdown/인용문 SHA와 물리 앵커 보존을 확인한다. 정상 앱 파일 sentinel에는 `CanvasDocumentSource.json`도 포함한다. 외장 출력의 `result.json`은 정확 입력 SHA·원본 불변·실제 helper 종료를 기록하며 tracked 결과 파일을 갱신하지 않는다. 기존 canvas-document 및 linked-obsidian runner는 새 제품의 누락된 컴파일 입력만 보완했다.

실제 socket HTTP, SwiftUI 손조작, iPad/Pencil, 설치, 실 Vault·Host 사용은 이 검사의 범위가 아니다. 전체 iOS27 SDK는 부모의 최종 정확 결합에서 한 번 수행한다. 독립 소스 검수·최종 SDK·기기 UI 수용 전 전체 기능 완료로 보고하지 않는다.

### PDF013 독립 반례 수리

Planck의 PDF-PRODUCT-R2(P1)는 제출 T1 crop0.8을 확인한 뒤 도착한 T2 crop0.6의 최종 복구 쓰기가 교체 후 오류를 반환했을 때, 네트워크 오류 catch가 이전 T1을 다시 쓰던 경계다. 저장 단계를 준비/전송/로컬확정으로 구분해 로컬 확정 오류를 PUT 실패로 처리하지 않는다. 기존 복구 writer는 오류 후 정본 바이트를 재조회하고 이전 관측값/정확 시도값 중 하나일 때만 해당 레코드를 메모리에 반영한다. 시도 바이트는 명시 재보존 전까지 남기며, 외부/손상/읽기 불가 값이면 쓰기를 차단한다. 오래된 캐시로 자동 재작성하거나 새 저장소·작업 ID를 만들지 않는다.

PDF-PRODUCT-R1(P2)은 공개 close가 진행 중 저장 request를 바꿔 그 소유자의 busy 해제를 잃던 경계다. Store의 close API 자체가 저장 중 닫기를 false로 명시 거부하고 Reader/의도/request를 보존한다. 늦은 응답은 기존 소유 request에서만 busy를 해제하므로 새 작업의 busy를 대신 해제하지 않는다. 실제 SwiftUI 수명 관측을 주장하지 않으며 원래 공개 호출 순서와 별도 연결 변경 대조로 검증한다.

`Tests/checks/pdf-view-product/repair.py --review <원래 독립 검수 폴더> --output <승인 외장 출력>`는 원래 main.swift를 수정 없이 직접 컴파일 입력으로 사용해 busy·cleanup 두 반례와 새 Store 자식만 실행한다. T2 0.6/SHA/동일 작업 ID/새 프로세스 복원을 원래 loss-values.json과 대조한다. 기존76·모듈147·iOS SDK는 반복하지 않는다. 제품 수리의 독립 재검수는 부모/Planck가 소유한다.
