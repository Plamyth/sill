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
