# PDF 페이지 탐색과 직각 회전 출처

기준은 공식624597f62326df776099e90a626630e52e751803/tree05d2249fbcef40f4c95d02316a75dd0e5f96a9ca다. 별도 codex/ipad-pdf-pages-rotation-20261029 / pdf-pages-rotation-20261029/source에서만 변경한다.

## 사용자 흐름

기존 보관함 PDF를 열고 이전·다음 또는 쪽 번호와 이동 버튼으로 문서를 탐색한다. 현재 쪽/전체 쪽과 선택이 속한 페이지를 표시한다. 유효한 페이지 이동은 이전 텍스트 선택을 비운다. 범위 밖 번호는 페이지와 선택을 바꾸지 않는다. PDFView의 직접 스크롤/내부 페이지 링크 이동도 현재 페이지 알림을 통해 표시를 갱신한다.

선택한 한 페이지의 텍스트를 기존 발췌 버튼으로 저장한다. canonical Markdown의 기존 pageIndex, PDF SHA, MediaBox/CropBox, rotation, 줄별 page-space rect, 실제 UTF16 textRanges와 quote를 사용한다. 사람용 링크의 page는1부터 시작한다. 기존 카드에서 원문 보기를 누르면 같은 PDF SHA의 해당 페이지와 문자 선택으로 돌아간다. 한 번의 발췌가 여러 페이지를 넘는 선택은 기존과 같이 명시적으로 거부한다.

PDFKit이0/90/180/270도로 해석한 페이지의 schema2 출처를 지원한다. 좌표는 PDFKit page space를 그대로 보존하며 y-flip, 원점 빼기, characterBounds 인덱스 변환을 추가하지 않는다. 원문 SHA·페이지 박스·회전·정확한 범위·quote/줄별 bounds가 같아야 복귀한다. geometry-only schema1의 지원은 기존 회전0으로 유지한다. 지원 밖 provenance 회전값과 손상·중복 출처는 계속 거부한다. 새 scene/노드 kind/schema/DB/의존성은 없다.

제목·메모 편집은 기존 VaultPDFCard와 vaultDraft를 사용한다. CAS와 GET, PDF 생성 journal, note/Canvas 복구 barrier를 변경하지 않는다. 다른 노트, 잉크, Files, 카드 Merge, relay와 인증 구현도 변경하지 않는다. 원문 PDF를 쓰거나 다시 직렬화하는 API는 없다.

## REA 근거와 구현 범위

기존 rea-stage1-20261021/margin-multipage-observed-spec.md에서 자체3페이지 문서의1/3쪽 이동, 쪽 표시/탭 재열기를 확인했다. margin-pdf-rotate-corrected-spec-v3.md와 margin-pdf-rotate-audit-acceptance.json에는 Mac 원앱 세 번째 페이지의90도 보기 회전, Undo/Redo 뒤90유지, 추가3회전으로 수동 원복 및 동일 프로세스 재열기가 기록돼 있다. 원래 PDF bytes는 보존됐고 원앱의 회전된 발췌 좌표는 미검증이다.

이번 CCR 지원은 PDFKit으로 읽힌 기존 PDF의 페이지 탐색·선택·앵커 복귀와 직각 회전된 PDF 좌표다. 원앱의 보기 회전 메타데이터 편집, Undo 동작, 책갈피/목차/페이지 추가·삭제·크롭, 전체 MarginNote 동등성으로 확대하지 않는다. 원앱 미관측 영역은 자체 PDFKit 기능 검사로 명시한다.

## 검사

Tests/checks/pdf-pages-rotation/PagesChecks.swift는 자체3페이지 PDF에 같은 단어를 페이지마다 두 번 넣는다. 기본 박스와 음수 원점 MediaBox/이동된 CropBox,0/90/180/270도를 실제 PDFKit/PDFView로 대조한다. 첫 단어의 PDFView 선택 정규화와 마지막 단어 선택을 모두 확인한다. 별도 source-return-probe에서 요청 NSRange와 actual currentSelection이 다를 수 있음을 확인했으므로 저장·재열기는 actual 선택 범위의 정확한 일치를 검사한다.

기존 linked-obsidian-notes runner의 --pdf-pages는 새 native 페이지 검사를 실행한다. --pdf-pages-files는 mini-ephemeral-source로 작업 전용 ObsidianVault의 실제 파일 CAS/GET을 실행하며 네트워크 listener/connect는 차단한다. 기존 PDFRemoteVault 표준입출력 bridge를 재사용하고 fixture backend는 각 요청마다 새 Vault 인스턴스를 연다. PDF_PAGES_REMOTE_SOURCE에는 이 작업의 소스 절대 경로를 전달한다. --pdf-pages-reopen은 같은 검사 HOME에서 새 Swift 프로세스로 실제 저장된 Markdown/PDF와 페이지·문자 선택을 복귀한다.

직접 파일 생성/재열기, 외부 메모 변경의 역수신, stale CAS409, create 응답 유실 뒤 동일 경로 확인, typed409 뒤 submittedText·page/rotation 보존과 자동 재시도0을 검사한다. 생성한 AppKit PDFView는 창·활성 앱을 열지 않는다. 실제 iPad UI/터치/Pencil·확대/회전 시각 수용, 공유 HTTP/Host/8791/8793, 설치·실사용 vault는 검사 범위 밖이다.

재현 명령은 기존 runner에 전용 출력 경로를 사용한다.

```sh
PDF_PAGES_REMOTE_SOURCE=/절대/담당/source python3 Tests/checks/linked-obsidian-notes/run.py /승인된/외장/evidence --pdf-pages
```

최종 source hash, 명령, 결과, Mini 원본 불변·PID/한시 사본 정리와 독립 검수는 담당 evidence의 영수증에 연결한다. 기존385/43 전체 검사를 무조건 반복하지 않는다. scoped commit을 부모에게 반환하고 공식 integration은 부모만 변경한다.

## 작성자 검사 결과

자체 native191건, 실제 ObsidianVault 파일40건, 새 Swift 프로세스 재열기25건, 직접 PDFView 페이지·선택 알림2건을 통과했다. iOS27 SDK typecheck exit0이며 이후 파일 검사에서는 동일한 제품 입력 SHA의 SDK 결과를 재사용했다. 파일 왕복40개 요청에서 원자 교환 helper8개의 정상 종료·PID 부재와 fixture 삭제를 확인했고 Mini wrapper는 exit0/cleanup_verified=true다. 초기 backend smoke의 한시 소스 정리 readback은 SSH 종료로 한 번 실패했으며 같은 소유 작업의 공식 cleanup 함수로 부재를 재확인했다. 원 실패 영수증과 후속 확인은 모두 보존한다.

첫 native 검사에서16건이 요청 범위와 actual PDFView 선택 범위를 같다고 가정해 실패했다. 별도 프로브에서 실제 저장 범위와 원문 복귀가 동일함을 확인하고 검사 전제를 실제 API 계약으로 수정했다. 해당 검사를 빼거나 제품 범위를 축소하지 않았다. 최종191건은 같은 단어의 첫/마지막 선택을 모두 대조한다.

기존 회귀385/카드43건, 기존 PDF HTTP 근거를 새로 실행한 것으로 세지 않는다. 실제 iPad UI·Pencil·설치·HTTP 수용은 별도다.

## 2026-10-29 후속: PDF 내장 목차 MM11.02

기준은 부모가 고정한 공식0c230d2ad0e360dcf7ee0ef31a849fc3832ef1a5/treeebe9215b7499a9cd8b7401807d9efcdb3e5852eb다. 기존 PDF WT를 새 codex/ipad-pdf-outline-20261029 브랜치로 재사용하며 기존900·docs2319 브랜치를 보존한다. 앞 절의 목차 미지원은900 당시의 범위이며 이 후속에서만 확장한다.

기존 PDF 페이지 조작부의 ‘목차’ 메뉴에서 PDFKit 내장 목차를 고르면 검증된 해당 쪽으로 이동한다. 새 DB·scene kind·bookmark·저장 원장은 없으며 목차는 열린 원본에서 파생한다. 원문 제목은 그대로 표시하고, 페이지 목적이 없는 그룹은 ‘이동할 쪽 없음’으로 비활성화한다. 그룹 아래의 유효한 항목은 들여쓰기해 별도로 선택할 수 있다. 목차가 없는 PDF는 ‘내장 목차 없음’으로 알리고 기존 페이지 탐색·텍스트 발췌를 유지한다.

PDFKit 구조를 반복문으로 평탄화하며 루트 아래 첫 단계는 depth0, 최대 depth8(화면상9단계), 검사하는 자식 슬롯은 최대256개다. 반복 객체를 다시 방문하지 않는다. 깊이/항목 상한 또는 반복 객체 때문에 일부를 제외하면 제한 안내를 표시한다. 원본 목차를 편집하거나 생략 항목을 다른 대상으로 대체하지 않는다.

목적은 같은 PDFDocument에 속한 실제 PDFPage만 허용한다. 로컬 PDFActionGoTo 또는 직접 destination을 해석하고 URL·다른 PDF·페이지 없는 목적은 실행하지 않는다. 항목 선택 때도 native document, 원래 outline root, 해당 Reader 소유 항목과 목적 페이지가 표시 당시와 같은지 확인한다. 검증 뒤에만 기존 go(toPageNumber:)로 이동해 옛 선택을 비운다. 거부 시 현재 페이지와 선택은 유지한다. 원본 PDF·기존 카드 ID/제목/인용/메모·sourceSHA·명시 CAS+GET·복구 barrier에는 쓰지 않는다.

R049의 실제 Mac 원앱 관측은 자체 rea-outline-controlled-20261021.pdf의 두 목차 선택·1/3쪽 이동·동일 프로세스 탭 재열기다. 입력 PDF SHA256은8ecbc452dfa4624c7479e2b86ff468278294a2da0f4da2f8458de08c81933ed0이며 저장 PDFKit 대조도3쪽·목차2개·목적0/2를 읽었다. 새 중첩/외부목적/상한 방어는 CCR 자체 안전 검사이고 그 원앱에서 추가 관측한 사실로 전이하지 않는다. MI12.04 원앱 iPad 상태·cold restart·책갈피 편집·전체 MarginNote 동등성은 수용하지 않는다.

검사는 기존 PagesChecks.swift와 linked-obsidian-notes/main.swift만 확장한다. 새 실행기 없이 --pdf-outline은 R049 실제 PDF/실제 PDFView·선택·Markdown 파일과 자체 경계 PDF를, --pdf-outline-reopen은 같은 격리 HOME에서 새 Swift 프로세스로 저장 PDF/카드 재열기를 검사한다. 원본 입력 PDF와 격리 복사본의 바이트, normal 보호 파일을 전후 대조한다. 같은 제품 입력의 iOS SDK typecheck를 수행하며 기존385/43/191 전체·HTTP·실기기를 반복하지 않는다.

```sh
PDF_OUTLINE_FIXTURE=/승인된/REA/rea-outline-controlled-20261021.pdf python3 Tests/checks/linked-obsidian-notes/run.py /승인된/외장/evidence/native --pdf-outline --pdf-isolated
```

실행 결과와 최종 정확 해시는 pdf-outline-20261029/evidence의 작성자 영수증에 연결한다. 실제 iPad 메뉴 줄바꿈·터치·시각 수용, 설치·공유서비스·Host·Pencil은 별도 부모 검증 경계다.

이 후속의 작성자 검사는 목차 전용 실제 PDFKit27건·새 Swift 프로세스 재열기5건을 통과했다. iOS27 SDK typecheck exit0이며 SDK/검사 입력의 전후 해시는 같았다. 기존 실행기의 normal 보호 파일도 불변이었다. PDFKit 종료 시 ‘Drawing a PDFPage when its PDFDocument is nil is unsupported’ 진단이 한 줄 있었으며, 해당 경계 fixture의 결과27/0과 원문 파일·보호 파일 불변을 따로 기록한다. 진단을 실기기 시각 수용이나 새 제품 실패로 추정하지 않는다. SDK의 기존 deprecation 경고도 원 로그에 보존한다.
