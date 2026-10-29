# EPUB Store·Workspace 접합 계약

기준은 부모 private `5fcb42cc1a1430a64210dd5d89c930a61fd8a0da` / tree `5c63f332fd6786adbd4291461c9f5b83e83f34c5`다. 소유 WT는 `epub-store-product-20261029/source`, branch `codex/ipad-epub-store-product-20261029`다. 그룹/하위 지도 Store·Workspace 구간, PencilCanvas/CanvasInkHistory, 공식 integration은 수정하지 않는다.

Pstack architect/how로 기존 PDF 생성 의도·note PUT/GET·파일 복구·문서 activation을 대조한다. Ponytail 순서에 따라 기존 note API·기록 파일·VaultNoteReference를 먼저 재사용한다. ARENA/순정Goal/새DB/새앱/GUI·기기·Host·설치·질문·알림0이다.

## 확정된 최소 확장과 책임

- 별도 scene source-kind 필드/scene wire는 추가하지 않는다. EPUB 출처는 Ohm `VaultEPUBExcerpt`의 Markdown source payload 한 곳에만 둔다. 기존 카드의 VaultNoteReference와 원문 노트를 사용한다.
- 기존 생성 복구 파일/스키마/ID와 nil인 PDF 필드를 그대로 유지하면서, 선택적 `sourceKind:"epub"`를 추가한다. nil은 기존 PDF만 뜻한다. EPUB을 PDF parser로 검증하지 않는다. 알 수 없는 kind는 디코드 거부로 원본을 유지하며, 구형 reader도 EPUB Markdown을 PDF로 수용하지 않는다. 병렬 복구 파일/원장은 만들지 않는다.
- 기존 token·Vault path 검증과 원본 bytes hash를 사용하는 최소 raw 읽기 DTO `{path,sha256,dataBase64}` 및 `GET /vault/epub?path=`를 사용한다. 목록에는 `kind:"epub"`만 추가한다. EPUB bytes 한도는 Ohm Snapshot의32MiB에 맞춘다. 서버 source 변경은 목록/원본 읽기만 좁은 별도 diff로 제공하며 실제 서비스/Host는 변경하지 않는다.
- 영향 파일: CanvasRelay.swift, CanvasStore.swift, CanvasWorkspace.swift, VaultPDFExcerpt.swift의 기존 복구 정의, 서버 obsidian-vault.js/server.js 목록·raw 읽기, 자체 접합 검사. 모델/ZIP/XML parser/Reader는 복제하지 않고 Ohm의 최종 Git commit만 소비한다. 현재 모듈 WT의 dirty 파일은 복사하지 않는다.

## 제품 경계

원본 읽기는 scene/document snapshot·페이지 activation epoch·연결 generation·Reader 소유를 확인한다. 발췌는 stable excerptID로 기존 durable 생성 의도를 PUT 전에 기록하고 명시404일 때만 create(nil-base)를 사용한다. 이미 존재하는 note는 정확 전체 본문 GET을 대조하며 기존 노트 수정을 nil-base로 우회하지 않는다. note CAS/전체GET·typed409·ACKunknown·외부 수정 복구는 기존 note 계약을 유지한다. 카드에서 복귀할 때 archive SHA/경로·spine item/장경로/XPath/UTF16/quote를 module의 resolve/reveal로 재검증한다.

모듈 최종 commit/독립 검수와 paired raw endpoint, 실제 Store/Files 검사 및 최종 SDK 전에는 전체 제품 완료로 표시하지 않는다. 실제 원앱 iPad 지원과 GUI/Pencil 수용은 계속 미검증이다.

## 부모 소유 범위의 계약 확정 (2026-10-29)

부모가 `70b3dc55` 반환 뒤 다음 두 최소 계약을 확정했다. 같은 승인/로그인 질문을 다시 전달하지 않는다.

1. 이 WT의 `server.js`/`obsidian-vault.js` 좁은 diff를 같은 CanvasRelay 단위로 소비한다. `GET /vault/epub?path=`의 `{path,sha256,dataBase64}`, 32MiB 상한, 기존 token/Vault·no-follow·inode/정본 경로 재조회 보호를 유지한다. `entries`에는 `kind:"epub"`만 추가한다. 기존 note/PDF 성공 DTO, 인증·기기 등록 권한은 변경하지 않는다. 실제 공유서비스 반영 전에 통합 담당이 영향 소비자에게 이 추가를 전달한다. 현재 정상서비스/Host는 변경하지 않았다.
2. 기존 `ccr.pdf-create-recovery/v1` 경로/envelope에 optional `sourceKind:"epub"`를 허용한다. nil은 엄격한 기존 PDF만 뜻한다. 알 수 없는 kind, EPUB+PDF `viewRecovery` 혼합, 다른 choice schema는 거부하고 원본을 보존한다. `ccr.epub-excerpt-note-choice/v1`과 `ccr.epub-excerpt-current-choice/v1`은 명시 구분하며 기존 choice/attempt 파일을 사용한다. 이름 일반화를 위한 파일/스키마 이관, 새 DB/병렬 원장은 만들지 않는다.

부모는 정확 `70b3dc55c7b6a5d4ba04fcca111647275d1f65fd` / tree `593ee57f0225fd80e8ceb3d8f05fbcf41dc7b9a1` 전체 iOS27 SDK 검사를 맡고, Laplace는 actual HTTP를 별도로 준비한다. 이 writer는 해당 검사/서비스를 중복 실행하지 않는다. 현재 계약 확정은 모듈 재검수·접합 독립 검수·HTTP·실제 UI/기기 수용을 대신하지 않는다. 전체 완료는 false다.

초기 `be702c64` 후보는 정확 `c4a74190e14c499dbfe536b9b2d0dd3f4961fecc` Git 객체를 병합했다. dirty 파일 복사는 없다. 그 시점의 Store 왕복·복구 UI 미완료와 아래 후속 구현/실행 상태를 구분한다. 모듈 수정은 원저자 exact commit으로만 소비한다.

후속 자체 native 실행에서 Store·전체 Files 왕복과 기존 note conflict 소비를 확인했다. EPUB Reader는 PDF 복구 안내에 종속되지 않는 본문 분기로 옮겼고, 기존 비교/선택 원장을 사용하는 한국어 복구 UI를 붙였다. 저장 중 닫기·미확인·외부 원문/동일 발췌 ID 확인은 Store가 계속 소유한다. 새 필드·추정 DTO·삭제·재전송 우회는 추가하지 않았다. UI는 source/syntax 단계이며 실제 화면 수용과 최종 iOS SDK는 남았다.

## 모듈 독립 검수와 접합 검사의 구분

Nash의 `epub-module-independent-review-c4a74190-20261029/REVIEW.md`는 c4에 P2 두 건으로 CHANGES_REQUESTED를 부여했다. MIME으로 읽는 `.dat` spine이 숨김 XHTML 검사를 우회하는 R1, NFC/NFD NCX fragment의 로딩/열기 identity가 다른 R2다. Ohm이 원 모듈에서 수리하며 이 writer는 해당 parser를 변경하거나 손상 원문을 표시하는 fallback을 추가하지 않는다. 후속 exact commit·재검수 전까지 모듈 SOURCE_CLEAR/공식 배포/전체 EPUB 수용은 false다.

후속 `e554bfb3cede02c5298760741d363f2e715fd41d` / tree `02a060a470482aa6e21830f95c56c111ec324361`을 Git 객체로 cherry-pick했다. 새 product delta는 `VaultEPUB.swift`만이며 공개 API/Markdown은 같다. 소비 커밋은 `b2a31519`다. 원저자의 native25·새 프로세스1과 원반례 수리 영수증은 `epub-product-20261029/evidence/repair-p2-a54821e8-9df1-435f-9ae3-e307b01ae3d1/HANDOFF-REPAIR.json`에 있다. 독립 재검수 대기이며 이를 SOURCE_CLEAR로 바꾸지 않는다.

`Tests/checks/epub-product/run.py --output <storage-route 외장 폴더>`는 자체 생성 ZIP/XHTML과 실제 Store·기존 원장·ObsidianVault 파일 처리·전체 Document Files를 사용한다. Node는 기존 네트워크 차단 guard 아래 stdio로 호출하며 HTTP endpoint·서비스·실제 GUI 수용 검사로 세지 않는다. 새 프로세스와 격리 Application Support의 원장 재열기를 별도로 관측하고, normal sentinel과 실행 입력 SHA를 보존한다. 이 검사는 모듈 두 반례의 수리·독립 수용을 대신하지 않는다. 부모의 두 계약은 위와 같이 별도로 확정됐다. 새 UI는 설치·활성화하지 않는다.

## 기존 54조건·새 프로세스 5회의 정확한 범위

실행 영수증은 `epub-store-product-20261029/evidence/native-d0ce2bf8-98cd-46bd-833e-b189b233e8e8/result.json`과 같은 폴더 `observations.json`이다. 부모54조건과 자식5회(각3개 관측)를 기능 수나 동등성 비율로 쓰지 않는다. 실행 HEAD는 `b2a31519`였고 소유 검사/Workspace가 dirty인 상태의 실제 입력63개 SHA를 기록했다. 그중 Store·모듈·Files·실행 검사 bytes는 `70b3dc55`와 같다. Workspace1개는 native 이후 본문 표시 분기와 명시 복구 UI를 보완했으므로 native 실행 완료로 그 UI를 수용하지 않는다. 최종 Workspace syntax만 별도 확인했으며 전체 SDK는 부모 검사다.

native는 실제 자체 ObsidianVault 파일 처리와 전체 Document Files generation/readback·새 Store, Markdown 외부 CAS 수정/역수신, 출처 SHA·장경로·XPath·UTF16 인용, 실제 파일 교환 뒤 보존형409와 명시 선택, 같은 stable ID의 미확인 결과 재조회, 페이지/연결 ABA·닫기 보호를 확인했다. ACK 유실·연결실패는 주입한 callback 경계이며 실제 HTTP/200 ACK 유실 관측이 아니다. 기존 세부 성공·실패 영수증과 원본 불변 근거는 덮어쓰지 않는다.

이번 부가 native는 새 계약의 거부/보존 입구만 확인하며 기존54·child5·모듈44/25·SDK 전체·actual HTTP는 반복하지 않는다. 제품 변경 없이 실제 격리 원장에 잘못된 kind/혼합/schema bytes를 넣고 Store 재열기·대체 거부·바이트 불변을 확인한다. 전체 수용은 계속 false다.

### 확정 계약의 부가 거부 경계 실행

`contract-6b090520-34a4-4d0c-86bd-531c5d0b7fb7/result.json`·`observations.json`에 부모34조건·새 프로세스1회(2개 관측), macOS27 compile/native exit0을 기록했다. 알 수 없는 kind, 명시 kind 없는 EPUB, 유효한 PDF viewRecovery와 EPUB의 혼합, EPUB으로 태그한 PDF payload, PDF/새버전/다른 EPUB choice schema의 교차 입력을 거부했다. 실제 격리 원장의 기존 bytes와 알림/전환 barrier를 보존했으며 invalid recovery 위에 새 생성 의도를 쓰거나 source loader를 호출하지 않았다. nil kind인 기존 PDF와 명시 EPUB envelope/choice의 정상 대조군도 수용했다. 이는 archive parser·일반 EPUB 전체 지원·새 HTTP·GUI 검사가 아니다.

원래54/child5 및 전체 SDK를 반복하지 않았다. 처음 부가 compile은 새 검사 fixture가 기존 Rect(CGRect) initializer를 잘못 호출해 실패했으며 `contract-d61ea99a-94d3-415d-8940-011b6b3fab93/result.json`에 보존했다. 검사 fixture만 수정했고 제품 validation은 바꾸지 않았다.

이 후속의 변경은 이 문서와 `Tests/checks/epub-product/{README.md,run.py,contract-boundaries.swift}`뿐이다. 제품은 `70b3dc55` 그대로이며 부모 SDK/Nash 입력을 보존한다. 앱·서버·프로토콜의 tracked 바이트 전체 대조는 `evidence/PRODUCT-BYTES-70b3dc55-during-contract-native.json`에 연결했다. 통합/설치/서비스 반영·최종 수용은 수행하지 않았다.
