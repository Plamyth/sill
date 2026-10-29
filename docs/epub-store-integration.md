# EPUB Store·Workspace 접합 계약

기준은 부모 private `5fcb42cc1a1430a64210dd5d89c930a61fd8a0da` / tree `5c63f332fd6786adbd4291461c9f5b83e83f34c5`다. 소유 WT는 `epub-store-product-20261029/source`, branch `codex/ipad-epub-store-product-20261029`다. 그룹/하위 지도 Store·Workspace 구간, PencilCanvas/CanvasInkHistory, 공식 integration은 수정하지 않는다.

Pstack architect/how로 기존 PDF 생성 의도·note PUT/GET·파일 복구·문서 activation을 대조한다. Ponytail 순서에 따라 기존 note API·기록 파일·VaultNoteReference를 먼저 재사용한다. ARENA/순정Goal/새DB/새앱/GUI·기기·Host·설치·질문·알림0이다.

## 최소 확장 제안과 책임

- 별도 scene source-kind 필드/scene wire는 추가하지 않는다. EPUB 출처는 Ohm `VaultEPUBExcerpt`의 Markdown source payload 한 곳에만 둔다. 기존 카드의 VaultNoteReference와 원문 노트를 사용한다.
- 기존 생성 복구 파일/스키마/ID와 nil인 PDF 필드를 그대로 유지하면서, 선택적 `sourceKind:"epub"`를 추가한다. nil은 기존 PDF만 뜻한다. EPUB을 PDF parser로 검증하지 않는다. 알 수 없는 kind는 디코드 거부로 원본을 유지하며, 구형 reader도 EPUB Markdown을 PDF로 수용하지 않는다. 병렬 복구 파일/원장은 만들지 않는다.
- 기존 token·Vault path 검증과 원본 bytes hash를 사용하는 최소 raw 읽기 DTO `{path,sha256,dataBase64}` 및 `GET /vault/epub?path=`를 제안한다. 목록에는 `kind:"epub"`만 추가한다. EPUB bytes 한도는 Ohm Snapshot의32MiB에 맞춘다. 서버 source 변경은 목록/원본 읽기만 좁은 별도 diff로 제공하며 실제 서비스/Host는 변경하지 않는다.
- 영향 파일: CanvasRelay.swift, CanvasStore.swift, CanvasWorkspace.swift, VaultPDFExcerpt.swift의 기존 복구 정의, 서버 obsidian-vault.js/server.js 목록·raw 읽기, 자체 접합 검사. 모델/ZIP/XML parser/Reader는 복제하지 않고 Ohm의 최종 Git commit만 소비한다. 현재 모듈 WT의 dirty 파일은 복사하지 않는다.

## 제품 경계

원본 읽기는 scene/document snapshot·페이지 activation epoch·연결 generation·Reader 소유를 확인한다. 발췌는 stable excerptID로 기존 durable 생성 의도를 PUT 전에 기록하고 명시404일 때만 create(nil-base)를 사용한다. 이미 존재하는 note는 정확 전체 본문 GET을 대조하며 기존 노트 수정을 nil-base로 우회하지 않는다. note CAS/전체GET·typed409·ACKunknown·외부 수정 복구는 기존 note 계약을 유지한다. 카드에서 복귀할 때 archive SHA/경로·spine item/장경로/XPath/UTF16/quote를 module의 resolve/reveal로 재검증한다.

모듈 최종 commit/독립 검수와 paired raw endpoint, 실제 Store/Files 검사 및 최종 SDK 전에는 전체 제품 완료로 표시하지 않는다. 실제 원앱 iPad 지원과 GUI/Pencil 수용은 계속 미검증이다.

## 부모의 계약 결정 대기

이 브랜치는 구현 중간 후보이며 아직 정식 제품 진입/수용 후보가 아니다. 부모 native ancestor 전달이 거부되는 경로는 다시 호출하지 않는다. 부모가 아래 두 계약의 소유·형식을 결정하면 같은 담당이 이어간다.

1. 같은 인증·Vault 경계의 `/vault/epub?path=` raw32MiB와 entries kind=epub를 이 writer의 소스 diff로 함께 소비할지, 서버 소유자가 별도 exact 단위로 반환할지. 현재 서버 소스는 이 WT에서만 좁게 구현했으며 서비스는 바꾸지 않았다.
2. 기존 `ccr.pdf-create-recovery/v1` envelope/파일 경로를 유지하고 sourceKind=epub로 명시 구분하는 호환 확장을 허용할지. nil PDF payload는 기존 형식 그대로다. 기존 NoteConflictChoice/Attempt 파일에도 `ccr.epub-excerpt-note-choice/v1`/`ccr.epub-excerpt-current-choice/v1`이라는 별도 명시 schema를 쓰는 분기를 제안한다. EPUB을 PDF source parser로 처리하지 않으며 구형 reader는 거부·보존한다. 부모가 공통 source 명칭/버전을 선택하면 그 소유 변경으로 의미 조정한다.

초기 `be702c64` 후보는 정확 `c4a74190e14c499dbfe536b9b2d0dd3f4961fecc` Git 객체를 병합했다. dirty 파일 복사는 없다. 그 시점의 Store 왕복·복구 UI 미완료와 아래 후속 구현/실행 상태를 구분한다. 모듈 수정은 원저자 exact commit으로만 소비한다.

후속 자체 native 실행에서 Store·전체 Files 왕복과 기존 note conflict 소비를 확인했다. EPUB Reader는 PDF 복구 안내에 종속되지 않는 본문 분기로 옮겼고, 기존 비교/선택 원장을 사용하는 한국어 복구 UI를 붙였다. 저장 중 닫기·미확인·외부 원문/동일 발췌 ID 확인은 Store가 계속 소유한다. 새 필드·추정 DTO·삭제·재전송 우회는 추가하지 않았다. UI는 source/syntax 단계이며 실제 화면 수용과 최종 iOS SDK는 남았다.

## 모듈 독립 검수와 접합 검사의 구분

Nash의 `epub-module-independent-review-c4a74190-20261029/REVIEW.md`는 c4에 P2 두 건으로 CHANGES_REQUESTED를 부여했다. MIME으로 읽는 `.dat` spine이 숨김 XHTML 검사를 우회하는 R1, NFC/NFD NCX fragment의 로딩/열기 identity가 다른 R2다. Ohm이 원 모듈에서 수리하며 이 writer는 해당 parser를 변경하거나 손상 원문을 표시하는 fallback을 추가하지 않는다. 후속 exact commit·재검수 전까지 모듈 SOURCE_CLEAR/공식 배포/전체 EPUB 수용은 false다.

후속 `e554bfb3cede02c5298760741d363f2e715fd41d` / tree `02a060a470482aa6e21830f95c56c111ec324361`을 Git 객체로 cherry-pick했다. 새 product delta는 `VaultEPUB.swift`만이며 공개 API/Markdown은 같다. 소비 커밋은 `b2a31519`다. 원저자의 native25·새 프로세스1과 원반례 수리 영수증은 `epub-product-20261029/evidence/repair-p2-a54821e8-9df1-435f-9ae3-e307b01ae3d1/HANDOFF-REPAIR.json`에 있다. 독립 재검수 대기이며 이를 SOURCE_CLEAR로 바꾸지 않는다.

`Tests/checks/epub-product/run.py --output <storage-route 외장 폴더>`는 자체 생성 ZIP/XHTML과 실제 Store·기존 원장·ObsidianVault 파일 처리·전체 Document Files를 사용한다. Node는 기존 네트워크 차단 guard 아래 stdio로 호출하며 HTTP endpoint·서비스·실제 GUI 수용 검사로 세지 않는다. 새 프로세스와 격리 Application Support의 원장 재열기를 별도로 관측하고, normal sentinel과 실행 입력 SHA를 보존한다. 이 검사가 모듈 두 반례의 수리나 부모의 두 계약 결정을 대신하지 않는다. 새 UI는 설치·활성화하지 않는다.
