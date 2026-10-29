# 다음 작업 — 공식 f09의 기존 구현을 유지한 후속 경계

기준은 `f09daa176fb9ff8ff45dcb30389eb06f33ea2b40` / tree `bd2347c35def444ca01dea8ec328c19e0ecffff0`다. 아래 현재 지시는 옛 “모듈이 없다/후보 통합부터”를 대체한다. 이미 구현된 기능을 다시 만들지 않는다. 기능 완료·실제 권한/GUI/기기 수용은 여전히 false다.

## 1. 페이지·Store·Files·복구: 구현 재작성 대신 정확 후속 대조

공식에는 전체 문서 공개 import/Files 목록·열기·선택·복제·페이지별 이력 소유권, 전체 JSON/PKDrawing/PNG 저장·재열기, 실제 relay synchronize/역수신과 지속 held/명시 후보복구가 있다. 따라서 MS14.03/MS12.03과 기존 Files/복구 행의 “단일 scene만/페이지 관리 전체 없음”은 현재 설명이 아니다. 범위는 coverage.json의 pagesStoreF09/filesDocumentF09/recoveryF09를 따른다.

남은 일은 f09에 없는 빈 페이지/순서 후보7e53의 원담당 검수·공식 반영 여부, iPad Files picker/bookmark·실제 FileProvider 지속성, 최종 UI/기기 구간이다. 순서 변경을 다른 API 작성자에게서 역수신한 HTTP 근거를 순서 편집 UI 구현으로 바꾸지 않는다. 전체 문서와 Files 계약·새 저장 DB를 다시 만들지 않는다. 제목 있는 서재/원앱 포맷 전체 해독·삭제/휴지통/GC/일반 클라우드 동등성은 별도다.

Helm이 수용한 Store79 원본과 증거 판정은 R175/R176이다. 성공200 ACK는 R178 작성자 결과와 Nash 검수 대기를 따로 유지한다. 새 HTTP·listener·프로세스·전체검사를 다시 발행하지 않는다.

## 2. 카드 병합·연결 해제: 있는 참조 병합의 의미와 수용만 확인

MM22.06/MM22.07의 대응 source는 이미 있다. `CanvasCardMerge`와 `confirmCardMerge/unmergeCard`는 일반 note2~20개를 순서대로 참조하고 원본·합친 유일 본문·기타 연결을 보존한다. R169/R170의 제한 SOURCE_CLEAR 모듈은 f09와 바이트가 같다. 새 병합 모델/저장 계약을 다시 구현하지 않는다.

원앱의 원본 이동/숨김을 포함한 전체 병합 의미, 중첩·그룹·하위 지도와 같은 다른 동작, 최종 iPad UI/권한 수용을 현재 참조 병합에 더하지 않는다. 그룹 작업은 원담당 후보를 기다리고 이 문서가 별도 대체 구현을 만들지 않는다.

## 3. 태그·Undo/Redo·필터/해제: 재구현 대신 남은 범위 분리

MM32.01~04에는 `CanvasCardTags`·예약 namespace `ccr.sill.card-tag/v1`·Store 입력 소유권·공통 graph history·note 보기 필터/해제·관리 Markdown/scene 계약이 이미 있다. 16e/4a/0c의 독립 검수와 통합을 재사용한다. SwiftUI `.tag`나 필기 검색을 분류 태그 구현의 유일한 근거로 보던 옛 지시는 더 이상 현재가 아니다.

R093/R094에서의 해제는 검색/보기 필터를 지워 다른 카드를 보이게 하고 저장 태그는 유지한 관측이다. 이를 영구 태그 삭제로 확대하지 않는다. 실제 Obsidian 인덱스, iPad 시각/터치, AND/OR·배치·계층 등 확인되지 않은 범위만 구분한다. 새 검색 서버나 태그 DB/모듈을 만들지 않는다.

## 공식과 후보의 경계

PDF900의 다중 페이지/원문 앵커 및 목차 계보는 존재한다. Helm013의 PDF 보기/Store 접합과 parent7e53의 빈 페이지/순서, 그룹/EPUB 진행 중 구현은 **미통합 후보**다. 예전 NEXT의 단일 PDF 후보 통합 지시도 그대로 실행하지 않는다. 원앱 지원 미확인32행은 유지하며 N/A 판정을 새로 만들지 않는다.

17행 진행 정정은 기능 완료가 아니다. 전 행 complete=false와 allAppsComplete/physical/runtime/testAccepted=false, 기존 385행/114그룹·원앱 관측/미확인·과거 ccr/checks를 유지한다. 과거 정상68/서명 후보 기록은 현재 런타임 직접 확인이 아니며 새 설치/GUI/Pencil 요청·알림은 이 문서 단위에서 발행하지 않는다.

## 아래는 이전 NEXT 전체 원문 — 현재 착수 지시가 아닌 이력

> # 다음 사용자 가치가 높은 미구현 행동 3개
>
> ## 2026-10-29 후속 — 과거 제안과 현재 근거의 구분
>
> 아래 세 제안은 9646469 당시 기록으로 보존한다. 공식9006908에서는 PDF 후보 통합과 다중 페이지 탐색·선택 페이지 앵커 저장/재열기/복귀·PDFKit 직각 회전 좌표 지원이 소스 후속으로 연결됐다. 따라서 아래 1번의 “PDFView/import/source-anchor 경로가 없다”와 “단일페이지 후보 의미 통합부터”는 당시 설명이며 현재 착수 지시가 아니다. `coverage.json`의 `implementationUpdates.pdfPagesRotation9006908` 및 README의 R160/R161을 따른다. 표시 순서/크롭 편집 뒤 복귀, 실제 iPad·HTTP·전체 회전 편집 수용은 이 후속으로 닫지 않았다. 2·3번 등 다른 담당의 후속 상태는 이번 범위에서 갱신하지 않는다.
>
> MyScript MS14.03/MS15.03에는 자체 문서145/페이지146→153의 복제·배경 변경·서재 재열기·원본 ink 보존 근거를 추가했다. cold restart·빈 페이지·순서 변경·실패 복구는 남는다. CCR 모델0fd의 미통합·제품 UI0 상태는 유지하며 이 원앱 근거로 제품 완료를 선언하지 않는다. 새 구현·빌드·UI·기기 작업은 발행하지 않았다.
>
> ## 보존한 9646469 당시 다음 행동
>
> 기준은 공식 `9646469ba63b2ed6a65c61a6384f541222dd5dee` / tree `4e8b7abf92485050610da334d6ec0166094adacb`다. 아래는 후속 제안이며 이번 문서 작업에서 제품을 구현하거나 설치하지 않았다. 판단 기준은 실제 관찰된 원앱 행동, 현재 제품의 공백, Obsidian 데이터로 이어지는 가치, 기존 후보 재사용 가능성이다. 테스트 개수나 새 진단 기반을 우선순위로 세지 않는다.
>
> ## 1. PDF 발췌 → Obsidian 저장 → 변형 뒤 같은 원문으로 복귀
>
> 독서 중 발췌를 카드/노트로 모으고 근거 원문으로 돌아갈 수 있어야 한다. 현재 소스에는 PDFView/import/source-anchor 경로가 없다. `CanvasStore.workspaceDocuments`와 `connectFileWorkspace`는 기존 `.sill` scene을 여는 경로이며 PDF를 불러오는 기능이 아니다. `VaultNoteReference`는 Markdown 블록 참조이고 PDF 페이지/영역 앵커를 대신하지 않는다.
>
> 원앱의 다중페이지·표시 순서·크롭 뒤 복귀/발췌 갱신은 R049/R054/R058/R062의 보존된 MarginNote Mac 관측이다. 관련 행 `MM15.04`, `MM15.05`, `MM14.06`을 기준으로 삼되, iPad 앵커 행 `MI16.*`의 근거 불충분과 Mac의 개별 미확인은 그대로 둔다. Mac 관측을 iPad 지원이나 cold reopen 수용으로 전이하지 않는다.
>
> 가장 작은 다음 단위는 **이미 검수된** PDF 후보 `6e796850c518d671a59014f33ffb54cdc7519c2f` / tree `7af7eecdb1f5a8cfe439c23caca02fc8abc66764`와 paired relay `2250dfada987013e6fc09e40e8bf2a58db134245`의 의미 통합부터다. R125는 회전 없는 단일페이지 텍스트 발췌의 native→Markdown/JSON 저장·재열기 범위만 뒷받침한다. 같은 후보를 다시 구현하지 않는다. 그 다음 관찰된 표시 순서 변경/다중페이지의 동일 원문 참조를 닫는다. 회전·크롭 전체를 후보의 완료 범위로 세지 않는다.
>
> 후속 완료 근거는 자체 PDF 원본 SHA/문서 ID·물리 페이지와 표시 순서·좌표계·발췌/노트 ID를 함께 고정하고 발췌→Obsidian/Files 저장→새 Store 재열기→원문 복귀를 실제 파일로 확인하는 것이다. 외부 수정·잘못된 앵커·취소는 원본과 미확정 자료를 보존해야 한다. 서비스/실기기 단계는 부모의 별도 조율 범위다.
>
> 근거: [다중페이지 R049](/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-stage1-20261021/margin-multipage-observed-spec.md), [순서 R054](/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-stage1-20261021/margin-pdf-order-observed-spec.md), [크롭 갱신 R062](/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-stage1-20261021/margin-pdf-crop-edit-observed-spec.md), [기존 후보 R125](/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/pdf-native-markdown-fix-20261026/source-handoff.json).
>
> ## 2. 원본 참조·순서를 보존하는 카드 병합·해제
>
> 여러 발췌를 한 논점으로 묶되 각 원문으로 돌아가고 다시 나눌 수 있어야 한다. 현재 `CanvasNode`/`CanvasLink`의 단일 노드와 parentChild/general 링크, `VaultNoteReference`는 이 행동을 구현하지 않는다. `CanvasStore.undoGraphEdit/redoGraphEdit`와 파일 CAS를 재사용할 수 있지만, 여러 원본 카드의 순서 있는 본문·출처·해제 계약은 현재 제품에 없다.
>
> 실제 원앱 근거는 `MM22.06`, `MM22.07`과 R081/R082다. 원래 두 카드 ID는 남고 병합 카드가 새로 생기며, 링크/텍스트 블록의 순서가 보존된다. 해제 뒤 빈 부모가 남을 수 있고 archive 바이트가 달라도 의미가 같았던 범위다. 원앱 Undo를 DB 바이트 완전 복원으로 해석하지 않는다. iPad의 같은 행동 수용은 별도다.
>
> 최소 단위는 자체 두 발췌의 ID·원문 참조·본문 순서를 저장하는 명시 병합/해제다. 기존 원본을 삭제하지 않고 공통 Undo·Files 저장·Obsidian Markdown과 scene의 대응을 유지한다. 다른 카드·노드·링크 보존, 새 Store 재열기, 외부 충돌·부분 저장 실패·취소의 원본 불변이 후속 검사의 핵심이다. 복습 알고리즘이나 전체 서재 프레임워크를 함께 만들 필요는 없다.
>
> 근거: [병합 정정 스펙 R081](/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-stage1-20261021/margin-card-merge-corrected-spec.md), [좁은 원앱 수용 R082](/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-stage1-20261021/margin-card-merge-audit-acceptance.json).
>
> ## 3. 태그 추가·Undo/Redo·필터·해제를 Obsidian 데이터와 연결
>
> 늘어난 발췌와 메모를 주제로 다시 찾는 기능이다. 현재 `searchHandwritingInk`는 필기 검색이고 SwiftUI Picker의 `.tag`는 선택값 표식이다. 둘 다 카드 분류 태그/필터가 아니다. 현재 scene 모델에 해당 태그 목록·필터 동작 근거가 없다.
>
> `MM32.01`~`MM32.04`와 R093/R094는 자체 한 카드의 태그 추가·Undo/Redo·재열기 화면·필터를 뒷받침한다. 프로세스 cold restart, 다중 카드 일괄 분류, iPad 동등성은 증명하지 않는다. 태그가 Markdown/TextNote 블록에 있고 topics 파생 색인이 달라진 관측을 단순 `ZBOOKTAG` 열 복제로 바꾸지 않는다.
>
> 최소 단위는 기존 노트 ID/Markdown 블록에 연결된 분류 태그를 명시 저장하고 같은 scene에서 필터·해제를 제공하는 것이다. 표현 계약은 Obsidian 기존 태그/파일 보존과 먼저 대조한다. 태그만 바뀌고 본문·잉크·원문 참조가 유지되는지, Undo/Redo·새 Store 재열기·외부 파일 충돌에서 같은 revision을 따르는지 검증한다. 별도 검색 서버나 인식 provider는 필요하지 않다.
>
> 근거: [태그 정정 스펙 R093](/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/margin-tag-analysis-20261021/margin-tag-corrected-spec.md), [좁은 원앱 수용 R094](/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/margin-tag-analysis-20261021/margin-tag-audit-acceptance.json).
>
> ## 기존 작업·남은 경계
>
> 원본 한 글자 삭제, 같은 줄 두 그룹 간격 편집, 사각형/타원/직선 후보, 교정 가능한 기본 산술, 외부 Files 원본과 명시 충돌 복구는 현재 제한 구현이 있다. 예전 NEXT의 “구현 근거 없음” 설명은 이 단위들에 더 이상 맞지 않는다. 다만 실제 native recognition의 가용성, 여러 글자/문단 의미 대응, 연속 후보 치환, 기존 수식 재교정·재계산은 여전히 간극이다. 주입 인식 검사나 nil 거부를 실제 한글/Pencil 성공으로 세지 않는다.
>
> EPUB 2장 리플로의 XPath/UTF16, 그룹/하위 맵, 적응형 복습, 다중 페이지 출력 등은 기존 385행에 유지한다. 이 제안 3개가 전체 미구현 목록은 아니다. MyScript의 새 `.nebo` REA 근거는 저장 파일 분리와 도형→페이지 참조 존재만이며 bdom 의미 해독이나 노트북 열기 성공이 아니다. MarginNote의 새 선택 4행 저장 관측도 OCR 전후 동작·인식 정확도·양방향 수정 수용을 대신하지 않는다.
>
> 정상 설치는 아직68이다. signed72는 공식9646469 소스의 로컬 서명/manifest/codeImages/파일 UUID 검증까지이며 설치·실행·Pencil 수용은 없다. 서명72 근거를 변경하지 않았다. 실제 폴더 선택·FileProvider 지속성·최신 기능의 UI/센서·저장/재열기·Mac 역수신은 부모가 source/보존/lease를 갖춘 뒤 하나의 최종 자체 fixture 구간으로 조율한다. 지금 새 기기 조회·사용자 입력 요청·UI 관측은 발행하지 않는다.
