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

모듈은 정확 `c4a74190e14c499dbfe536b9b2d0dd3f4961fecc` Git 객체를 병합했다. dirty 파일 복사는 없다. 향후 모듈 수정은 원저자 exact commit으로만 소비한다. 이미 작성한 발췌 생성·snapshot/연결/page epoch·원문 복귀·기존 note conflict 소비 코드의 일부 UI/회귀 접합은 진행 중이다. 전체 Store 왕복·EPUB 신규복구 UI·최종 SDK·독립 수용은 아직 완료하지 않았다.
