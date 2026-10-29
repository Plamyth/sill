> 범위 안내: 아래 f09 진행표는 그 커밋 시점의 검증 기록입니다. 이후 공식 `5fcb42cc1a1430a64210dd5d89c930a61fd8a0da`에는 빈 페이지·순서 변경과 PDF 보기 저장·복구 수리가 통합됐습니다. 펜 설정을 가진 빈 페이지의 표현 버전 수리 `edba258141b67e5dee6bcc6bdcda08d6cdb6dca5`도 별도 소스 검수를 통과했습니다. 이 후속을 f09의 과거 후보 상태와 혼동하지 않습니다. 현재 원앱·기기 수용과 전체 완료는 여전히 별도이며, 그룹·EPUB는 각각의 정확 후속 판정을 따릅니다.

# REA 기능 조사·구현 진행표

## 현재 구현 기준 — 공식 f09, 기능 완료와 분리

현재 source는 **`f09daa176fb9ff8ff45dcb30389eb06f33ea2b40` / tree `bd2347c35def444ca01dea8ec328c19e0ecffff0`**다. R162/R163의 공식 push/readback·clean·sourceguard와 R164의 기존 `program/units.tsv` 읽기 snapshot을 대조했다. 현재 판독 순서는 `coverage.json.currentProgress` → 각 행의 `currentProgress/remaining/status` → `implementationUpdates`다. 기존 `ccr/checks`, sourceFileRegistry13개, 원앱 관측과 아래 옛 설명은 당시 이력이며 새 구현 착수 지시가 아니다.

| 이미 존재하는 제한 구현 | 실제 f09 파일·진입점 | 재사용한 근거와 다음 경계 |
|---|---|---|
| 전체 문서 Store·페이지 선택/복제·전체 import/Files 열기 | `CanvasDocument.swift`, `CanvasDocumentFiles.swift`, `CanvasStore.importSourceBytes/connectDocumentWorkspace/selectDocumentPage/duplicateDocumentPage`, `CanvasWorkspace.swift` | R165/R166/R167의 source 검수. 제목 있는 원앱 서재·`.nebo` 해독 전체는 아니다. 빈 페이지·임의 순서 이동·삭제/휴지통은 f09에 없으며 7e53 후보를 공식으로 오인하지 않는다. |
| 원본 보존형 참조 카드 병합·명시 연결 해제 | `CanvasCardMerge.swift`, `CanvasStore.confirmCardMerge/unmergeCard` | R169/R170. 일반 note2~20개·순서 링크와 표시 본문, 원본·합친 유일 본문 보존. 원앱의 원본 이동/숨김·그룹·중첩 병합 전체 동등성은 아니다. 검수 모듈 바이트와 f09가 같다. |
| 태그 추가·공통 Undo/Redo·보기 필터/해제 | `CanvasCardTags.swift`, `CanvasStore.finishCardTagInput/setCardTagFilter`, `canvas-card-tags.js` | R171/R172/R173/R174. 예약 author `ccr.sill.card-tag/v1`로 일반 댓글과 분리한다. 필터 해제는 저장 태그를 삭제하지 않는다. 실제 Obsidian 인덱스·다중 조건·배치·영구 태그 삭제 전체를 완료로 세지 않는다. 검수 모듈 바이트와 f09가 같다. |
| 전체 Files 세대·같은 내용 저장 재사용·원본 캐시 보호 | `CanvasDocumentFiles.save/load`, `CanvasStore.saveDocumentWorkspace/restoreDocumentSource`, `CanvasModel.swift` | R165/R167/R168. 실제 native Files/새 Store 증거가 있으나 Mac DEBUG requiresScope=false·fixture PNG 범위다. iPad 선택 권한/bookmark·FileProvider 지속성과 GC/전체 누적 상한은 별도다. |
| 보존 충돌·지속 held·명시 후보 선택/전체 GET 재열기 | `CanvasStore.synchronizeDocumentToVault/refreshDocumentFromVault/readDocumentConflict/resolveDocumentConflict`, `CanvasDocumentRelay.swift`, 실제 Node `obsidian-vault.js` | R175/R176의 f09 Store→Files→Node→별도 Store와409 응답 유실·네 후보·명시 복구. 절대 CAS/자동 rollback·원앱 클라우드 전체 동등성으로 설명하지 않는다. |

**385행 ID/114그룹·분모와 원앱 상태·미확인은 그대로다.** 17행의 현재 진행/남은 행동을 정정했고, 그중 “구현 근거 미확인”이던 7행은 제한 구현이 있는 `parity_gap`으로 옮겼다. 현재 분포는 parity_gap127·implementation_evidence_missing220·support_unverified32·integration_pending6, 완료0/미완료385/N/A0이다. `complete`는 전 행 false, `allAppsComplete`와 현재 physical/runtime/testAccepted도 false다. 테스트 수는 기능 수가 아니다.

### scoped 실행 증거와 독립 판정

- [R175 실제 Store79 원본](/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-completion-20261028/document-store-http-evidence/FINAL-NATIVE-STORE-HTTP-f09.json)과 [R176 Helm 독립 증거 검수](/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-completion-20261028/document-store-http-review-helm-f09/result.json)의 판정은 `EVIDENCE_CLEAR_SCOPED_NATIVE_STORE_HTTP_F09`다. macOS DEBUG의 실제 Files/socket/별도 프로세스와 보존 충돌 자료에 대한 제한 수용이다. 이 판정을 새 source 검수·앱 runtimeAccepted·실제 iPad/렌더/Pencil 수용으로 합산하지 않는다. 과거 R162 영수증의 `actualStoreHTTP:false`는 그 영수증 발급 당시 상태이며 원문을 고치지 않는다.
- [R178 성공200 ACK 후속 작성자 결과](/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-completion-20261028/document-store-http-evidence/FINAL-SUCCESS200-ACK-f09.json)는 이번 요청 기준 **Nash 독립 검수 대기**다. writer의 socket/snapshot 관측이 존재한다는 사실만 연결하고 accepted/source/runtime 수치에 더하지 않는다. 기존79의 Helm 판정은 성공200 경계를 포함하지 않는다.
- 기존 PDF900 다중 페이지/직각 회전 앵커와 PDF 목차는 공식 소스 계보다. Helm013의 PDF 보기/Store 접합, parent7e53의 빈 페이지/순서, 진행 중 그룹/EPUB는 f09 밖의 후보다. 실제 파일에 후속 모듈이 보인다는 이유로 현재 공식 기능으로 올리지 않는다.

새 제품/원앱/HTTP/프로세스/SDK/GUI·기기 검사는 실행하지 않았다. 정상 설치68은 마지막 보존 metadata이고 현재 직접 조회가 아니다. 최종 권한·GUI·실기기 구간은 기존 부모가 조율하며 여기서 새 질문·알림·실행을 발행하지 않는다. 다음 행동은 [NEXT.md](NEXT.md), 이번 문서 검증은 [외장 validation.json](/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-completion-20261028/coverage-progress-f09-evidence/validation.json)에 남긴다. 기존 `verification.json`은 옛 문서판 검증 원본으로 유지한다.

## 이하: 보존한 이전 900/964 문서 원문

아래 “현재”·“미구현”은 해당 절의 당시 기준이다. f09의 현재 진행과 착수 판단에는 위 표와 기계 원장의 currentProgress/nextActions를 사용한다.

## 2026-10-29 후속 근거 — 공식 PDF900 기준

이번 문서 작업의 기준은 `9006908998dbcbe0b278b3dc75c71d5d2006342a` / tree `c9d3fd1f19996328c191672ed30ef3051b9d7f3f`다. 아래의 기존 본문·385행 표는 **9646469 당시 snapshot**으로 보존한다. `coverage.json`의 기존 source snapshot·13개 sourceFileRegistry·상태·과거 count도 바꾸지 않았다. 새 사실은 `additionalOriginalEvidence`, `implementationUpdates.pdfPagesRotation9006908`, `evidenceFollowups`에서 구분한다.

- **MS14.03 페이지 복제:** 자체 문서145의 원본146을 복제해153이 생겼고, 서재에서 같은 문서를 재열어 2/2와 기존 내용 유지를 확인했다. 원본 packed 바이트와 두 페이지 ink.bink는 유지됐다. 두 패키지 내부의 `qoxhavla`는 같으므로 전역 ID가 아니다. 외부 페이지 UUID와 부모145의 child_index로 146→153의 저장 순서를 대조했으며, 순서 변경을 실행한 근거는 없다. [R156](/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/myscript-page-management-20261029/observation.json), [R159](/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/myscript-page-data-final-20261029/result.json).
- **MS15.03 배경 변경:** 복제 페이지153의 회색 격자와 기존 내용, 원본146의 검은 thumbnail이 서재→문서 재열기에도 유지됐다. 저장 자료는 153의 background_pattern=grid·page.bdom 변경과 원본/양쪽 ink 바이트 보존을 뒷받침한다. 색상은 화면 관측이며 저장 색상 필드 해독은 아니다. R159의 당시 배경 재열기 미검증을 지우지 않고 이후 R158로 보완한다. R157에 기록된 240초 허용/343초 경과/103초 초과도 보존한다. [R157](/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/myscript-page-management-20261029/background-observation.json), [R158](/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/myscript-page-management-20261029/background-reopen-observation.json).

두 행동 모두 자체 표본의 좁은 원앱 관측이다. cold restart·빈 페이지 삽입·순서 변경·전체 오류 복구는 미검증이다. 저장 자료는 자체 문서 투영의 안정된 읽기이며 앱 전체의 원자적 snapshot이 아니다. CCR 복수 페이지 모델 `0fd`는 미통합·제품 UI0이므로 원앱 사실을 CCR 완료로 옮기지 않는다.

**PDF900 소스 후속:** 기존 한 페이지·회전0 후보의 한계를 다중 페이지 탐색, 선택한 한 페이지의 앵커 저장·재열기·원문 복귀, schema2의 PDFKit 해석 0/90/180/270도 page-space 좌표 범위에서 닫았다. canonical Markdown·sourceSHA·명시 CAS+GET·복구 barrier를 재사용하고 schema1 회전0은 유지한다. 이전 한 페이지 설명과 후보 미통합 기록은 역사로 남는다. 원본/보기회전 편집, 페이지를 가로지르는 하나의 발췌, 표시 순서·크롭 편집, 실제 iPad/HTTP/설치 수용이나 전체 MarginNote 동등성은 아니다. [R160 최종 영수증](/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-completion-20261028/pdf-pages-rotation-20261029/evidence/FINAL-RECEIPT.json), [R161 Sartre 독립 검수](/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-completion-20261028/pdf-pages-rotation-independent-review-9006908/result.json). 부모의 공식 반영 완료 통지와 이 영수증을 재사용하며 추가 ACK·제품 검사·원격 검사를 반복하지 않았다.

현재 원장에서 다시 계산한 값은 385행/114그룹, 미완료385/완료0, parity_gap120·implementation_evidence_missing227·support_unverified32·integration_pending6이다. 기존155개 근거를 보존하고 새6개를 더해161개다. 원앱 후속2행·PDF 소스 후속5행은 기능 완료 수에 더하지 않는다. 원앱 historical status와 원장 status 변경은 모두0이다. 이번 제품 코드·빌드·테스트틀·UI·기기·Host·실사용 vault·공유서비스 변경도0이다.

R153의 현재 원본 경로에는 이후 `followup` 객체가 추가돼 당시 해시·크기와 다르다. 기존 registry는 그대로 유지하고, 추가 객체를 제외했을 때 당시 1422바이트/SHA256이 정확히 재현됨을 확인했다. 복원본과 현재 파일 해시는 `evidenceFollowups[].historicalEvidenceReadback`에 별도로 남겼다. 현재 경로가 과거 해시와 같다고 보고하지 않으며, 새 두 행동은 R156~R159로만 뒷받침한다.

## 보존한 9646469 당시 기록

문서 기준은 공식 integration `9646469ba63b2ed6a65c61a6384f541222dd5dee` / tree `4e8b7abf92485050610da334d6ec0166094adacb`이다. 목표는 MyScript Notes와 MarginNote의 사용자 행동을 CCR Sill의 Obsidian 데이터 흐름으로 재현하는 것이다. **전체 완료는 false, 최종 동등성 완료는 0행**이다. 기존 385행 ID와 114 원행, 원앱 관찰·지원 미확인·false는 보존했다. 385는 조사 질문의 행동 분해이며 확인된 기능 수나 완료율의 분모가 아니다.

이번 변경은 문서만 소유한다. 기존 제품 검사와 독립 검수 영수증을 읽었고 제품 테스트를 다시 실행하지 않았다. 원앱·기기·GUI·Host·사용자 vault·서비스 변경은 0이다. 기계 판독 원장은 [coverage.json](coverage.json), 다음 행동 제안은 [NEXT.md](NEXT.md), 문서 정합성 결과는 [verification.json](verification.json)이다.

## 버전과 수용 경계

| 단계 | 확인된 사실 | 아직 확인되지 않은 사실 |
|---|---|---|
| 공식 소스 | 9646469 / 4e8b7abf. 제한 글리프/간격/도형/수식/Files/충돌 접합이 존재한다. [R132](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/product-integration-9646469.json) · [R133](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/client-integration-9646469-check/reconciliation-a398902e-c4a5-4b9c-bead-d9f96b8ddddf/result.json) | 원앱 전체 동등성, 실제 최신 iPad 실행 |
| 자동검사 | exact9646469 격리 Store/Workspace·SDK; 개별 기능은 아래 원래 소스와 검사 범위만 재사용한다. [R133](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/client-integration-9646469-check/reconciliation-a398902e-c4a5-4b9c-bead-d9f96b8ddddf/result.json) · [R134](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/relay-reconciled-http-20261029/evidence/FINAL-RECEIPT.json) | 검사 개수는 기능 개수나 센서 인식 성공이 아니다. paired HTTP는 clientbc61/server2c90의 격리 근거다. |
| 서명 후보 | 정식 Xcode build72, source9646469. 기존 cached profile·Automatic·provisioning flags 없음. 서명/전체 manifest/main+dylib 파일 SHA·LC_UUID 로컬 검증. [R144](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/signed-candidate72-20261029/artifact-verification/result.json) · [R145](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/signed-candidate72-20261029/prepared-artifact-receipt.json) | 설치·현재 실행 이미지·loaded UUID·media lease·relay readiness. 첫 Manual 실패도 원본 위치에 보존한다. |
| 현재 설치 | 부모가 보존한 normal68 metadata와 기존 source14e9410/tree4c1081a9 설치 계보. [R005](/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/pencil-work-resume-20261026.json) · [R146](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/preinstall-current-sill-20261029.json) · [R147](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/fresh-runner-metadata-readback-20261029.json) | metadata를 현재 코드 서명 직접 readback이나 새 기능 수용으로 확대하지 않는다. runner1도 제품 기능 완료가 아니다. |
| 실물 | 과거 46/47/58의 좁은 삭제/join/split/가방 저장·재열기 성공은 기존 행의 역사적 근거로 유지한다. | 새 9646469/72 기능의 실제 iPad·Pencil·외부 FileProvider 지속성은 미수용이다. |

signed72 영수증 SHA는 `eb5094d4536409a6641ea5c115cd60b188bb5962e2cd903fac522ac792909e1d`, 검증 결과 SHA는 `ee76a891b21fed572fdad21002c7bfeb0ddc1e933e5a05743b0c48a1be68a6f7`다. 이번 문서 작업에서 내용을 바꾸지 않았다.

## 현재 연결한 제한 구현

아래 항목은 행의 일부 행동을 뒷받침하는 근거다. 원앱의 제스처·인식·저장·재열기·오류 처리 전체를 재현했다는 뜻은 아니다. 각 파일의 정확 해시는 coverage.json의 sourceFileRegistry에, 실제 진입점과 검사 범위는 implementationUpdates에 있다.

| 구현 | 현재 동작 | 구현 파일 | 재사용 검사·통합 근거 | 남은 간극 |
|---|---|---|---|---|
| 원본 획 한 글자 삭제 | 유일한 한 글자와 검색 획의 대응을 검증해 native 미리보기·명시 확정·문자와 획의 Undo/Redo·복구본/Files 저장을 제공한다. scratch 자동 판별이나 새 교정 후보 엔진은 아니다. | [CanvasStore.swift](../../iOSClient/CanvasBridge/CanvasStore.swift) · [CanvasWorkspace.swift](../../iOSClient/CanvasBridge/CanvasWorkspace.swift) · [CanvasModel.swift](../../iOSClient/CanvasBridge/CanvasModel.swift) · [CanvasInkTextEditing.swift](../../iOSClient/CanvasBridge/CanvasInkTextEditing.swift) | 실제 Store/PKDrawing/JSON/Files와 격리 Obsidian 모듈 왕복. 문자↔획 근거는 주입; 무주입 native recognition 성공 없음. [R138](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/glyph-integration-land.json) · [R139](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/glyph-product-checks/handoff.json) · [R148](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/glyph-product-checks/policy-464336a2-a10b-44f5-a58f-076aaf0fa487/verification.json) | 실제 인식이 nil/모호하면 원본 유지. 새 한글 글리프 성공·Pencil 센서 미수용. 한 글자 삭제만. 후보 치환·다중 글자·전체 문장 대응은 구현 완료 아님. |
| 같은 줄 두 그룹의 원본 획 간격 편집 | 전체 선택과 유일 note의 두 그룹 대응을 검증해 정수1~512pt 간격 합치기/나누기·미리보기·명시 확정·공통 graph Undo/Redo를 연결한다. | [CanvasStore.swift](../../iOSClient/CanvasBridge/CanvasStore.swift) · [CanvasWorkspace.swift](../../iOSClient/CanvasBridge/CanvasWorkspace.swift) · [CanvasModel.swift](../../iOSClient/CanvasBridge/CanvasModel.swift) · [CanvasInkSpacingProposal.swift](../../iOSClient/CanvasBridge/CanvasInkSpacingProposal.swift) | 실제 Store/PKDrawing/Files CAS·새 Store 재열기·지연 callback·history IO 실패 검사. mapping/preview 주입. [R141](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/ink-spacing-product-checks/handoff.json) · [R142](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/ink-spacing-product-parent-review/result.json) · [R133](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/client-integration-9646469-check/reconciliation-a398902e-c4a5-4b9c-bead-d9f96b8ddddf/result.json) | 같은 줄·확인된 두 그룹·전체 선택·정수만. 문단 join/split·mask/회전/모호한 대응은 거부. 현재 최종 editor 접합은 source/SDK만 수용; iPad 실제 UI·Pencil 미수용. |
| 선택 잉크의 사각형·타원·직선 후보 | 선택한 원본 획은 유지하고 geometry 근거의 후보를 명시 확정해 sourceStrokeIds를 가진 schema3 도형 노드를 만든다. native 잉크를 삭제하거나 원앱 전체 의미 인식 엔진을 재현한 것은 아니다. | [CanvasStore.swift](../../iOSClient/CanvasBridge/CanvasStore.swift) · [CanvasWorkspace.swift](../../iOSClient/CanvasBridge/CanvasWorkspace.swift) · [CanvasModel.swift](../../iOSClient/CanvasBridge/CanvasModel.swift) · [CanvasInkShapeProposal.swift](../../iOSClient/CanvasBridge/CanvasInkShapeProposal.swift) · [SceneRenderer.swift](../../iOSClient/CanvasBridge/SceneRenderer.swift) · [CanvasPeleView.swift](../../iOSClient/CanvasBridge/CanvasPeleView.swift) | geometry/native/Files 보존, 실제 비활성 macOS SVG/선 helper, 실제 CanvasRelay URLProtocol gate; 후속 격리 paired HTTP scene3/승격 근거. [R139](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/glyph-product-checks/handoff.json) · [R149](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/glyph-product-checks/combined-e3dd1436-ed1a-4aa1-aeaa-fcaa84aa8fc3/combined-verification.json) · [R150](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/glyph-product-checks/combined-e3dd1436-ed1a-4aa1-aeaa-fcaa84aa8fc3/schema3-native-verification.json) · [R134](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/relay-reconciled-http-20261029/evidence/FINAL-RECEIPT.json) | 세 도형의 제한된 geometry 후보이며 연결선/자유도형 의미 인식 전부가 아니다. Pele 자동 배치 투영과 native 좌표/회전은 별개. 실제 iPad 터치·Pencil·시각 수용 미완료. |
| 선택 잉크의 교정 가능한 기본 산술 | 선택 원본/인식 후보를 보여 주고 사용자가 교정한 숫자·소수·괄호·사칙연산을 명시 확정해 결과 note에 원본 획 ID와 함께 저장한다. | [CanvasStore.swift](../../iOSClient/CanvasBridge/CanvasStore.swift) · [CanvasWorkspace.swift](../../iOSClient/CanvasBridge/CanvasWorkspace.swift) · [CanvasModel.swift](../../iOSClient/CanvasBridge/CanvasModel.swift) · [CanvasInkMathProposal.swift](../../iOSClient/CanvasBridge/CanvasInkMathProposal.swift) | 실제 Decimal 계산/입력·stale/cancel·PKDrawing/Files IO·SDK. 인식 결과는 주입; 실제 native 수식 recognition 성공 미증명. [R140](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/math-product-checks/handoff.json) · [R151](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/math-product-checks/math-4a924f48-9ee4-4cc3-acb5-d3b4d348fb55/result.json) | 유한 Decimal 기본 산술만. 변수·함수·LaTeX·근삿값·일반 수식 엔진 미지원. 기존 확정 수식의 양방향 재편집/재계산이 아니라 신규 결과 note 생성. native 인식·iPad/Pencil 미수용. |
| Files 외부 폴더 원본·복구본 분리 | 사용자 선택 외부 폴더·bookmark·파일 조정을 통해 scene/drawing/preview 세대를 원본으로 저장/복원하고 CAS·권한/IO/취소/재시작 충돌에서는 원본과 pending을 보존한다. Files 미연결 기존 Obsidian 정본은 허용한다. | [CanvasStore.swift](../../iOSClient/CanvasBridge/CanvasStore.swift) · [CanvasWorkspace.swift](../../iOSClient/CanvasBridge/CanvasWorkspace.swift) · [CanvasModel.swift](../../iOSClient/CanvasBridge/CanvasModel.swift) · [SceneFile.swift](../../iOSClient/CanvasBridge/SceneFile.swift) | 실제 로컬 파일 roundtrip/새 인스턴스/외부 변경/손상 캐시·callback 취소 보존. security-scoped 실제 provider 지속성 검사는 아님. [R136](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/storage-integration-land.json) · [R137](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/storage-review/recheck-15fe6aa5/review.json) · [R139](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/glyph-product-checks/handoff.json) · [R142](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/ink-spacing-product-parent-review/result.json) · [R133](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/client-integration-9646469-check/reconciliation-a398902e-c4a5-4b9c-bead-d9f96b8ddddf/result.json) | 기존 .sill scene identity 열기만. 제목 있는 서재/새 노트북/페이지 관리 전체는 없다. 앱 자체 Documents/ApplicationSupport는 공용 원본으로 성공 처리하지 않는다. 실제 iPad 폴더 선택/bookmark·삭제분리 지속성 미수용. |
| Obsidian 명시 충돌 자료 비교·선택·복구 | 현재/기준/외부/제안본과 SHA를 대조하고 명시 선택을 PUT→재조회해 적용한다. 보존 choice/local/attempt는 CanvasConflictRecovery 아래에 두고 Files CAS·pending·현재 입력 barrier를 유지한다. | [CanvasStore.swift](../../iOSClient/CanvasBridge/CanvasStore.swift) · [CanvasWorkspace.swift](../../iOSClient/CanvasBridge/CanvasWorkspace.swift) · [CanvasModel.swift](../../iOSClient/CanvasBridge/CanvasModel.swift) · [CanvasRelay.swift](../../iOSClient/CanvasBridge/CanvasRelay.swift) | exact9646469 격리 실제 Store/Workspace async body/File API·SDK 및 clientbc61/server2c90의 실제 격리 HTTP 파일 교환. 사용자 vault/live service/기기 실행0. [R132](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/product-integration-9646469.json) · [R133](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/client-integration-9646469-check/reconciliation-a398902e-c4a5-4b9c-bead-d9f96b8ddddf/result.json) · [R135](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/conflict-ui-independent-review/final-bc61/review.json) · [R134](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/relay-reconciled-http-20261029/evidence/FINAL-RECEIPT.json) · [R143](/Volumes/BT-Workspace/Development-Archives/BT_CCR-iPad/rea-completion-20261028/adapter-runtime-independent-review/final-6502f97/result.json) | exact 구현된 두 결정과 barrier/IO 복구만. 원앱 클라우드 동기화·자동 병합 전체 동등성은 미수용. 최종 signed 후보의 UI·실기기·media/relay 구간·Pencil은 대기. |

원본 획 대응 검사는 실제 PKDrawing·Store·파일을 쓰지만 일부 recognition/mapping은 주입 근거다. nil·모호함 거부는 안전성 증거이며 실제 손글씨 인식 성공 증거가 아니다. PDF 후보6e796850/relay2250dfad와 BT 후보163aa1f0는 별도 후보로 남겨 두며 현재 소스에 포함되었다고 표시하지 않는다.

## 10월 29일 추가 조사 근거의 경계

- MyScript의 보존 REA 컨테이너 view는 `ev_3567242aaf048d2a98a430c4b125363ce8a4765e083a72d8006a4146dfdeb696`에 연결된다. committed.nebo SHA는 `3145d69853222c77feb9fa9ee15f3ab03d0481a26730ffa320fbacce3b0619de`다. 8개 view 항목은 root 1개와 ZIP entry 7개이며 `index.bdom`/`page.bdom`/`ink.bink`/`style.css`/`rel.json`이 분리된다. `rel.json`은 `rectangle/4`, `rectangle/5`에서 `kqpajsha` 페이지를 참조한다. **저장구조 존재만** 확인하며 bdom 의미·전체 동작 수용은 아니다. R152.
- 자체 노트북의 표지 메뉴와 인라인 이름 편집 진입은 CUA 관측이고 마지막 열기 결과는 미확인이다. 노트북 생성·복제·열기·재열기 완료로 바꾸지 않았다. R153.
- MarginNote 자체 백업의 REA 선택 4행은 편집 텍스트와 원필기 media 참조가 분리됨을 보여 준다. `ZRECOGNIZE_TEXT`의 JSON 메타데이터를 OCR 문자열로 복제하지 않는다. OCR 전후 동작·글자별 대응·정확도·cold reopen은 미수용이다. R154/R155.

추가 원본은 coverage.json의 `additionalOriginalEvidence`와 행의 `additionalOriginalEvidenceRefs`로만 연결한다. 기존 original/support/complete와 원앱 상태 분포는 바꾸지 않았다. 새 UI/REA 도구/기기관측을 실행하지 않았다.

- [R152](/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/myscript-diagram-archive-rea-20261029.json)
- [R153](/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/myscript-own-notebook-open-observation-20261029.json)
- [R154](/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/margin-own-editable-ocr-rea-20261029.json)
- [R155](/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/margin-own-editable-ocr-findings-20261029.md)

## 상태 분포와 변경 범위

| 원장 상태 | 행 수 | 의미 |
|---|---:|---|
| `parity_gap` | 120 | 일부 구현/역사적 성공은 있으나 해당 원앱 행동 전체 동등성은 미완료 |
| `implementation_evidence_missing` | 227 | 현재 읽은 근거로 대응 구현을 확인하지 못함. 원앱의 비지원 판정이 아님 |
| `support_unverified` | 32 | 원앱 지원부터 미확인. 임의 구현 계획이나 N/A로 전환하지 않음 |
| `integration_pending` | 6 | 별도 검수 후보가 공식 소스·설치에 미접합 |

21행에 현재 제한 구현을 연결했다. 그중 7행은 구현 근거 미확인에서 parity_gap으로만 이동했다. complete는 전부 false이며 support_unverified 32행과 원앱 상태는 그대로다. 겹치는 질문 6행의 sameBehaviorAs도 보존했다. 이전 c03d 기준 설명과 ccr 필드는 historicalSnapshot/priorCoverageSnapshot에서 추적할 수 있다.

## 385행 현재 진행표

원앱 열은 original.status를 그대로 옮긴다. 관찰=behavior_observed, 좁은완료=legacy_narrow_complete, 시도=attempt_observed, 근거불충분=evidence_incomplete, 지원미확인=support_unverified다. **원앱의 관찰은 CCR의 구현/수용이 아니다.**

소스의 “제한 접합”은 위 구현 묶음의 일부만 연결된 상태다. “과거 근거”는 기존 ccr 근거를 보존했으나 exact9646469에서 기능별로 재검증하지 않았다는 뜻이다. 자동검사 열의 참조는 원래 검사 범위를 따른다. 통합·설치·실물 열은 별도로 읽어야 한다. 모든 행의 상세 입력/결과/저장/재열기/취소, 파일·근거 SHA와 미완료 사유는 coverage.json에 있다.

| ID | 행동 | 원앱 | 현재 소스 | 자동검사 근거 | 통합 | 설치 | 현재 실물 수용 |
|---|---|---|---|---|---|---|---|
| MS01.01 | 후보를 골라 오인식을 교정한다 | 관찰 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS02.01 | 손글씨 가운데 글자를 scratch로 삭제한다 | 관찰 | 제한 접합: glyph | R138 R139 R148 | 9646469 일부 | 68 / 새기능 미설치 | 미수용 |
| MS02.02 | 변환된 인쇄체 글자를 scratch로 삭제한다 | 관찰 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS02.03 | 단어를 의미 단위로 삭제한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS03.01 | 같은 줄의 두 단어를 합친다 | 관찰 | 제한 접합: spacing | R141 R142 R133 | 9646469 일부 | 68 / 새기능 미설치 | 미수용 |
| MS03.02 | 문단 경계를 합친다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS04.01 | 단어 중간에 공백을 넣어 나눈다 | 관찰 | 제한 접합: spacing | R141 R142 R133 | 9646469 일부 | 68 / 새기능 미설치 | 미수용 |
| MS04.02 | 문단을 나눈다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS05.01 | 펜 연결 시험 후 원래 액티브 펜 설정으로 돌아온다 | 좁은완료 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS06.01 | 새 손글씨의 인식 결과를 읽는다 | 관찰 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS06.02 | 손글씨를 편집 가능한 인쇄체로 변환한다 | 관찰 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS07.01 | 문서에서 두 번 탭해 변환한다 | 관찰 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS07.02 | 노트북에서 변환 지원을 확인한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS07.03 | 보드에서 변환 지원을 확인한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS08.01 | 펜으로 쓴다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS08.02 | 마커로 강조한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS08.03 | 색을 바꿔 다음 획에 적용한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS08.04 | 굵기를 바꿔 다음 획에 적용한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS08.05 | 자로 직선을 긋는다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS09.01 | 획 지우개로 한 획을 지운다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS09.02 | 정밀 지우개로 획 일부를 지운다 | 관찰 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS09.03 | 지우개 크기를 바꿔 지운다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS10.01 | 올가미로 필기를 선택한다 | 관찰 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS10.02 | 선택 필기를 이동한다 | 시도 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS10.03 | 선택 필기를 확대한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS10.04 | 선택 필기를 복사한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS11.01 | Pencil 필기 중 손가락으로 탐색한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS11.02 | 손바닥 접촉을 무시한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS11.03 | Pencil 더블탭으로 도구를 전환한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS11.04 | 스퀴즈를 사용한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS11.05 | 호버를 확인한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS11.06 | 필압을 획에 반영한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS12.01 | 노트북을 만든다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS12.02 | 문서를 만든다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS12.03 | 라이브러리에서 기존 자료를 다시 연다 | 근거불충분 | 제한 접합: files | R136 R137 R139 R142 R133 | 9646469 일부 | 68 / 새기능 미설치 | 미수용 |
| MS13.01 | 보드를 만든다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS13.02 | 무한 작업면을 탐색한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS14.01 | 페이지를 추가한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS14.02 | 페이지 순서를 바꾼다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS14.03 | 페이지를 복제한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS14.04 | 페이지를 삭제한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS14.05 | 삭제한 페이지를 복구한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS15.01 | 용지를 바꾼다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS15.02 | 필기 언어를 선택한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS15.03 | 배경을 바꾼다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS15.04 | 가이드를 사용한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS16.01 | 키보드 텍스트를 저장하고 앱 재실행 후 읽는다 | 좁은완료 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS17.01 | 텍스트 편집을 실행 취소한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS17.02 | 텍스트 편집을 다시 실행한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS17.03 | 필기 변경을 실행 취소한다 | 근거불충분 | 제한 접합: glyph, spacing | R138 R139 R148 R141 R142 R133 | 9646469 일부 | 68 / 새기능 미설치 | 미수용 |
| MS17.04 | 필기 변경을 다시 실행한다 | 근거불충분 | 제한 접합: glyph, spacing | R138 R139 R148 R141 R142 R133 | 9646469 일부 | 68 / 새기능 미설치 | 미수용 |
| MS18.01 | 손그림 상자를 사각형으로 보정한다 | 관찰 | 제한 접합: shape | R139 R149 R150 R134 | 9646469 일부 | 68 / 새기능 미설치 | 미수용 |
| MS18.02 | 손그림 선을 직선으로 보정한다 | 관찰 | 제한 접합: shape | R139 R149 R150 R134 | 9646469 일부 | 68 / 새기능 미설치 | 미수용 |
| MS18.03 | 상자를 옮길 때 연결선이 따라온다 | 관찰 | 과거 근거 | 기존 R003,R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS18.04 | 끝점을 도형 경계에 다시 붙인다 | 관찰 | 과거 근거 | 기존 R003,R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS18.05 | 끝점 수정을 취소하고 다시 실행한다 | 관찰 | 과거 근거 | 기존 R003,R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS18.06 | 도형을 회전한다 | 관찰 | 과거 근거 | 기존 R003,R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS19.01 | 스케치를 삽입한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS19.02 | 삽입한 스케치를 편집한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS20.01 | 수식 상자를 삽입한다 | 관찰 | 제한 접합: math | R140 R151 | 9646469 일부 | 68 / 새기능 미설치 | 미수용 |
| MS20.02 | Pencil 식을 인쇄체로 인식한다 | 관찰 | 제한 접합: math | R140 R151 | 9646469 일부 | 68 / 새기능 미설치 | 미수용 |
| MS20.03 | 1+1을 계산해 2를 표시한다 | 관찰 | 제한 접합: math | R140 R151 | 9646469 일부 | 68 / 새기능 미설치 | 미수용 |
| MS20.04 | 변환된 식을 교정하고 재계산한다 | 시도 | 제한 접합: math | R140 R151 | 9646469 일부 | 68 / 새기능 미설치 | 미수용 |
| MS21.01 | PDF를 가져와 읽는다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS21.02 | PDF에 주석을 쓴다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS21.03 | PDF 페이지를 탐색한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS22.01 | EPUB 입력 지원을 확인한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS23.01 | PDF 발췌 지원을 확인한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS23.02 | PDF 원문 앵커와 복귀 지원을 확인한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS24.01 | 학습 카드 지원을 확인한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS24.02 | 학습 계층과 마인드맵 지원을 확인한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS24.03 | 간격 복습 지원을 확인한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS25.01 | 텍스트를 검색한다 | 관찰 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS25.02 | 손글씨를 검색한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS25.03 | 검색 결과 위치로 이동한다 | 관찰 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MS26.01 | 이미지를 삽입한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS26.02 | 카메라로 첨부한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS27.01 | 오디오 첨부 지원을 확인한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS27.02 | 영상 첨부 지원을 확인한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS27.03 | 첨부와 필기 시간 연결 지원을 확인한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS28.01 | 폴더로 조직한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS28.02 | 자료를 정렬한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS28.03 | 자료를 이동한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS28.04 | 태그 지원을 확인한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS28.05 | 휴지통에서 복구한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS28.06 | 라이브러리를 검색한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS29.01 | 노트북을 PDF로 내보낸다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS29.02 | 노트북을 PNG로 내보낸다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS29.03 | 노트북을 SVG로 내보낸다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS29.04 | 노트북을 nebo로 내보낸다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS30.01 | 문서를 텍스트로 내보낸다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS30.02 | 문서를 PDF로 내보낸다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS30.03 | 문서를 DOCX로 내보낸다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS30.04 | 문서를 nebo로 내보낸다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS31.01 | 현재 버전의 자체 nebo 패키지를 확보한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS31.02 | nebo 백업을 복원한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS31.03 | 버전 호환성을 확인한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS32.01 | 자료를 동기화한다 | 근거불충분 | 제한 접합: files | R136 R137 R139 R142 R133 | 9646469 일부 | 68 / 새기능 미설치 | 미수용 |
| MS32.02 | 다른 기기에서 읽는다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS32.03 | 오프라인에서 수정한다 | 근거불충분 | 제한 접합: files | R136 R137 R139 R142 R133 | 9646469 일부 | 68 / 새기능 미설치 | 미수용 |
| MS32.04 | 충돌을 복구한다 | 근거불충분 | 제한 접합: files, conflict | R136 R137 R139 R142 R133 R132 R135 R134 R143 | 9646469 일부 | 68 / 새기능 미설치 | 미수용 |
| MS33.01 | AI 응답을 받는다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS33.02 | AI 요약을 만든다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS33.03 | 문서에 질문한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS33.04 | AI 결과를 적용한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS34.01 | 설정을 확인한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS34.02 | 도움말을 연다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS34.03 | 권한 거부를 처리한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS34.04 | 접근성을 확인한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MS34.05 | 구매 조건을 확인한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM01.01 | Pencil 교정 입력 지원을 확인한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM02.01 | 글자와 단어 의미 삭제 지원을 확인한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM03.01 | 문자 합치기 지원을 확인한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM04.01 | 문자 나누기 지원을 확인한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM05.01 | 펜으로 쓴다 | 관찰 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM05.02 | 마커로 강조한다 | 관찰 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM05.03 | 지우개로 지운다 | 관찰 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM05.04 | 자를 사용한다 | 관찰 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM05.05 | 도형 보정을 사용한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM05.06 | 소멸 잉크를 사용한다 | 관찰 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM06.01 | 필기를 인식한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM06.02 | 그림 인식을 확인한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM06.03 | 카드에 필기를 연결한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM07.01 | 도형을 인식한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM07.02 | 연결선을 의미 구조로 편집한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM08.01 | 수식 인식과 계산 지원을 확인한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM09.01 | 스터디셋을 만든다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM09.02 | 문서를 추가한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM09.03 | 스터디셋을 다시 연다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM10.01 | 자체 한 페이지 PDF를 가져와 읽는다 | 좁은완료 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM11.01 | PDF 페이지를 탐색한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM11.02 | 목차로 이동한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM11.03 | 책갈피를 추가하고 다시 찾는다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM11.04 | PDF 보기를 회전한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM11.05 | 페이지 표시 순서를 바꾼다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM11.06 | PDF 보기 영역을 자른다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM11.07 | 자르기를 취소하고 다시 실행한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM11.08 | PDF 주석을 편집한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM12.01 | EPUB를 가져온다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM12.02 | EPUB를 리플로한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM12.03 | EPUB 서식을 바꾼다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM12.04 | 읽기 위치를 복원한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM13.01 | Core를 발췌해 카드 제목과 함께 저장하고 다시 연다 | 좁은완료 | 별도 후보 | R125 R004 R005 | 미통합 | 후보 미설치 | 미수용 |
| MM14.01 | 문장을 발췌한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM14.02 | 다중 범위를 발췌한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM14.03 | 영역을 발췌한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM14.04 | 그림을 발췌한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM14.05 | 발췌를 Extend로 연장한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM14.06 | 원문 변경 후 발췌 미리보기를 갱신한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM15.01 | PDF 앵커를 저장하고 원문으로 돌아간다 | 근거불충분 | 별도 후보 | R125 R004 R005 | 미통합 | 후보 미설치 | 미수용 |
| MM15.02 | 확대 후 같은 앵커로 돌아간다 | 근거불충분 | 별도 후보 | R125 R004 R005 | 미통합 | 후보 미설치 | 미수용 |
| MM15.03 | 회전 후 같은 앵커로 돌아간다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM15.04 | 표시 순서 변경 후 같은 앵커로 돌아간다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM15.05 | 크롭 후 같은 앵커로 돌아간다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM16.01 | EPUB XPath 앵커로 돌아간다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM16.02 | UTF16 범위를 유지한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM16.03 | 리플로 후 앵커로 돌아간다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM16.04 | NCX 목차로 이동한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM17.01 | 카드 본문 일부를 키보드로 편집하고 취소 및 재시작 후 확인한다 | 좁은완료 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM18.01 | 카드 댓글을 편집한다 | 관찰 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM18.02 | 댓글 서식을 바꾼다 | 관찰 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM18.03 | 제목을 본문과 별도로 편집한다 | 관찰 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM18.04 | 원문 댓글을 편집한다 | 관찰 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM19.01 | 참조 카드의 공유 본문을 편집한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM19.02 | 참조 카드의 독립 질문을 편집한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM19.03 | 참조에서 원문으로 돌아간다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM20.01 | 부모와 자식 계층을 만들고 뷰 전환 및 재시작 후 확인한다 | 좁은완료 | 과거 근거 | 기존 R003,R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM21.01 | 카드를 접는다 | 관찰 | 과거 근거 | 기존 R003,R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM21.02 | 카드를 펼친다 | 관찰 | 과거 근거 | 기존 R003,R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM22.01 | 수동 관계를 만든다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM22.02 | 관계를 해제한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM22.03 | 카드를 그룹으로 묶는다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM22.04 | 그룹을 해제한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM22.05 | 하위 맵을 만든다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM22.06 | 카드를 병합한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM22.07 | 병합을 해제한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM22.08 | 자동 배치를 사용한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM23.01 | 맵과 개요를 전환한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM23.02 | 부모와 자식에 포커스한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM23.03 | 포커스를 해제한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM23.04 | 가지 스타일을 바꾼다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM24.01 | 복습 덱을 만들고 카드를 편입해 재시작 후 읽는다 | 좁은완료 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM25.01 | 복습 앞뒤를 뒤집는다 | 관찰 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM25.02 | 질문을 지정한다 | 근거불충분 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM25.03 | 복습에서 원문으로 돌아간다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM25.04 | Cloze를 설정한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM26.01 | 좋음 평가를 선택하고 완료 상태를 확인한다 | 관찰 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM27.01 | 다시 5분 평가를 실행한다 | 관찰 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM27.02 | 같은 복습에 다시 진입한다 | 좁은완료 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM27.03 | 평가 없이 중지한다 | 좁은완료 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM28.01 | 하드 평가를 실행한다 | 관찰 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM28.02 | 좋음 평가를 실행한다 | 관찰 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM28.03 | 쉬움 평가를 실행한다 | 관찰 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM29.01 | 다시 평가의 만기 시각을 저장한다 | 관찰 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM29.02 | 기한 필터로 목록을 확인한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM29.03 | 중복 평가를 처리한다 | 근거불충분 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM29.04 | 시간 변경을 처리한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM29.05 | 재열기 후 일정을 유지한다 | 관찰 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM30.01 | 몰입 읽기를 사용한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM30.02 | 몰입 쓰기를 사용한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM30.03 | 회상을 사용한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM30.04 | 음성 복습을 사용한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM31.01 | 본문을 검색한다 | 관찰 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM31.02 | OCR 문자를 검색한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM31.03 | 태그 범위를 검색한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM31.04 | 검색 순위를 확인한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM31.05 | 검색 결과로 이동한다 | 관찰 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MM32.01 | 태그를 추가한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM32.02 | 태그를 취소하고 다시 실행한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM32.03 | 태그로 필터한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM32.04 | 태그를 해제한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM32.05 | 해시태그를 관리한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM32.06 | 일괄 분류한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM33.01 | 이미지를 붙여넣는다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM33.02 | 오디오를 첨부한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM33.03 | 영상을 첨부한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM33.04 | 첨부 순서를 바꾼다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM33.05 | 누락 첨부를 복구한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM34.01 | 녹음을 시작한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM34.02 | 녹음을 일시정지한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM34.03 | 음성과 필기 시간을 연결한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM35.01 | 스터디 백업을 만들고 DB와 PDF를 읽는다 | 좁은완료 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM36.01 | 백업을 다시 가져온다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM36.02 | 버전 이력을 복원한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM36.03 | 중복 문서를 처리한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM36.04 | 가져오기를 취소한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM37.01 | 카드를 PDF로 출력해 본문을 읽는다 | 좁은완료 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM38.01 | 맵을 PDF로 출력한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM38.02 | 개요를 PDF로 출력한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM38.03 | 긴 이미지를 출력한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM38.04 | 페이지 배치를 바꾼다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM39.01 | 기본 Anki 템플릿으로 출력한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM39.02 | 맞춤 Anki 템플릿으로 출력한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM39.03 | DOCX로 출력한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM39.04 | 다른 맵 형식으로 출력한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM39.05 | 다른 개요 형식으로 출력한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM40.01 | 동기화 OFF 설정을 재시작 후 확인한다 | 좁은완료 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM41.01 | 자료를 동기화한다 | 근거불충분 | 제한 접합: files | R136 R137 R139 R142 R133 | 9646469 일부 | 68 / 새기능 미설치 | 미수용 |
| MM41.02 | 다른 기기에서 읽는다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM41.03 | 오프라인에서 수정한다 | 근거불충분 | 제한 접합: files | R136 R137 R139 R142 R133 | 9646469 일부 | 68 / 새기능 미설치 | 미수용 |
| MM41.04 | 충돌을 해결한다 | 근거불충분 | 제한 접합: files, conflict | R136 R137 R139 R142 R133 R132 R135 R134 R143 | 9646469 일부 | 68 / 새기능 미설치 | 미수용 |
| MM41.05 | 자료를 공유한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM42.01 | AI 응답을 받는다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM42.02 | OCR을 실행한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM42.03 | 번역한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM42.04 | Custom AI를 실행한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM42.05 | 결과를 적용한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM43.01 | Database Channel을 전환한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM43.02 | 외부 Agent로 내보낸다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM43.03 | Agent 결과를 가져온다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM44.01 | 확장을 실행한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM44.02 | 충돌을 복구한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM44.03 | 구매 조건을 확인한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM44.04 | 도움말을 연다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM44.05 | 설정을 바꾼다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MM44.06 | 화면을 탐색한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI01.01 | Pencil 문자 교정을 확인한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI02.01 | 글자와 단어 의미 삭제 지원을 확인한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI03.01 | 문자 합치기 지원을 확인한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI04.01 | 문자 나누기 지원을 확인한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI05.01 | 펜으로 쓴다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI05.02 | 마커로 강조한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI05.03 | 부분 지우개로 지운다 | 관찰 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI05.04 | 획 지우개로 지운다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI05.05 | 자를 사용한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI05.06 | 색을 바꾼다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI05.07 | 굵기를 바꾼다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI06.01 | Pencil 필기 중 손가락으로 탐색한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI06.02 | 손바닥 접촉을 무시한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI06.03 | 기기별 펜 동작을 사용한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI07.01 | 필기를 OCR로 변환한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI07.02 | OCR 문자를 키보드로 편집한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI07.03 | 원필기를 OCR 카드에 연결한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI07.04 | 올가미로 필기를 선택한다 | 관찰 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI07.05 | 선택 필기를 이동한다 | 관찰 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI07.06 | 선택 필기를 축소한다 | 관찰 | 과거 근거 | 기존 R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI08.01 | 도형을 보정한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI08.02 | 연결선을 편집한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI08.03 | 다이어그램을 인식한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI09.01 | 수식을 인식한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI09.02 | 수식을 계산한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI10.01 | 라이브러리에서 Files를 연다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI10.02 | 자체 PDF를 가져온다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI11.01 | 자체 한 페이지 PDF를 읽는다 | 좁은완료 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI12.01 | PDF 페이지를 탐색한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI12.02 | PDF를 회전한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI12.03 | PDF를 확대한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI12.04 | 목차로 이동한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI12.05 | 책갈피를 사용한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI12.06 | PDF 페이지를 편집한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI13.01 | EPUB를 가져온다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI13.02 | EPUB를 리플로한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI13.03 | EPUB 서식을 바꾼다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI14.01 | Core를 손가락으로 선택하고 강조해 카드를 만든다 | 좁은완료 | 별도 후보 | R125 R004 R005 | 미통합 | 후보 미설치 | 미수용 |
| MI15.01 | 문장을 발췌한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI15.02 | 영역을 발췌한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI15.03 | 그림을 발췌한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI15.04 | 다중 페이지를 발췌한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI15.05 | 발췌를 Extend로 연장한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI16.01 | PDF 앵커를 저장한다 | 근거불충분 | 별도 후보 | R125 R004 R005 | 미통합 | 후보 미설치 | 미수용 |
| MI16.02 | 발췌에서 원문으로 돌아간다 | 근거불충분 | 별도 후보 | R125 R004 R005 | 미통합 | 후보 미설치 | 미수용 |
| MI16.03 | 변형 뒤 같은 앵커로 돌아간다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI17.01 | EPUB 앵커로 돌아간다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI17.02 | UTF16 범위를 유지한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI17.03 | 리플로 후 앵커로 돌아간다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI18.01 | 카드 제목을 편집한다 | 좁은완료 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI18.02 | 카드 인용을 확인한다 | 좁은완료 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI18.03 | 카드 댓글을 편집한다 | 좁은완료 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI19.01 | 카드 본문 일부를 편집한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI19.02 | 본문 서식을 바꾼다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI19.03 | 본문 편집을 취소한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI19.04 | 삭제를 복구한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI20.01 | 참조 카드를 복사한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI20.02 | 공유 본문을 편집한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI20.03 | 독립 복제본을 만든다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI21.01 | 부모와 자식을 연결한다 | 근거불충분 | 과거 근거 | 기존 R003,R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI21.02 | 카드를 그룹으로 묶는다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI21.03 | 수동 링크를 만든다 | 근거불충분 | 과거 근거 | 기존 R003,R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI21.04 | 하위 맵을 만든다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI22.01 | 카드를 접는다 | 근거불충분 | 과거 근거 | 기존 R003,R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI22.02 | 카드를 펼친다 | 근거불충분 | 과거 근거 | 기존 R003,R004,R005,R006 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI22.03 | 개요로 전환한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI22.04 | 포커스를 사용한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI22.05 | 스타일을 바꾼다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI22.06 | 배치를 바꾼다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI23.01 | 복습 메뉴를 연다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI23.02 | 복습 덱을 만든다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI23.03 | 카드를 복습에 편입한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI24.01 | 앞면을 읽는다 | 관찰 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI24.02 | 뒤집어 뒷면을 읽는다 | 관찰 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI24.03 | 질문을 지정한다 | 근거불충분 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI24.04 | 원문을 본다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI24.05 | Cloze를 사용한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI25.01 | 다시 5분을 실행한다 | 관찰 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI25.02 | 하드 10분을 실행한다 | 관찰 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI25.03 | 좋음 1일을 실행한다 | 관찰 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI25.04 | 쉬움 2일을 실행한다 | 관찰 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI25.05 | 기한 필터를 확인한다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI25.06 | 복습을 중지한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI25.07 | 재열기 후 일정을 확인한다 | 관찰 | 과거 근거 | 기존 R004,R005 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI26.01 | 몰입 읽기를 사용한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI26.02 | 몰입 쓰기를 사용한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI26.03 | 회상을 사용한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI26.04 | 음성 복습을 사용한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI27.01 | 본문을 검색한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI27.02 | OCR 문자를 검색한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI27.03 | 태그 범위를 검색한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI27.04 | 결과로 이동한다 | 근거불충분 | 과거 근거 | 기존 R004,R005,R006,R123,R124 | 현재 기능별 미검증 | 과거 근거만 | 미수용 |
| MI28.01 | 이미지를 첨부한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI28.02 | 오디오를 첨부한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI28.03 | 영상을 첨부한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI28.04 | 녹음한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI28.05 | 첨부와 필기 시간을 연결한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI29.01 | 폴더로 조직한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI29.02 | 태그를 사용한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI29.03 | 해시태그를 사용한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI29.04 | 자료를 정렬한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI29.05 | 휴지통에서 복구한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI30.01 | 공식 스터디 백업을 만든다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI30.02 | 백업을 복원한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI30.03 | 버전 이력을 복원한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI31.01 | Flatten PDF로 내보낸다 | 관찰 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI31.02 | 긴 이미지로 내보낸다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI31.03 | DOCX로 내보낸다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI31.04 | Anki로 내보낸다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI31.05 | 맵과 개요로 내보낸다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI32.01 | 동기화 OFF와 재시작 후 경고 부재를 확인한다 | 좁은완료 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI33.01 | 자료를 동기화한다 | 근거불충분 | 제한 접합: files | R136 R137 R139 R142 R133 | 9646469 일부 | 68 / 새기능 미설치 | 미수용 |
| MI33.02 | 다른 기기에서 읽는다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI33.03 | 오프라인에서 수정한다 | 근거불충분 | 제한 접합: files | R136 R137 R139 R142 R133 | 9646469 일부 | 68 / 새기능 미설치 | 미수용 |
| MI33.04 | 충돌을 해결한다 | 근거불충분 | 제한 접합: files, conflict | R136 R137 R139 R142 R133 R132 R135 R134 R143 | 9646469 일부 | 68 / 새기능 미설치 | 미수용 |
| MI33.05 | 자료를 공유한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI34.01 | AI 응답을 받는다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI34.02 | OCR을 실행한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI34.03 | 번역한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI34.04 | Custom AI를 실행한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI35.01 | Database Channel을 전환한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI35.02 | 외부 Agent로 왕복한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI35.03 | 확장을 실행한다 | 지원미확인 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI36.01 | 설정을 확인한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI36.02 | 권한 거부를 처리한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI36.03 | 구매 조건을 확인한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI36.04 | 도움말을 연다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI36.05 | 접근성을 확인한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |
| MI36.06 | 중단한 화면을 재개한다 | 근거불충분 | 대응 근거 미확인 | 해당 기능 근거 없음 | 현재 기능별 미검증 | 미확인 | 미수용 |

## 이력·원본 보존

기존 114 원행과 REA evidence ID/정정 스펙은 coverage.json의 groups/evidenceRegistry에 유지했다. 원행의 좁은 완료를 삭제하지 않았고, 원앱 저장 미확인·오류 관측을 성공으로 바꾸지 않았다. Mac MarginNote 관측을 iPad나 MyScript의 지원/성공으로 전이하지 않는다. EPUB XPath/UTF16, PDF 회전/순서/크롭, 관계/그룹/병합, 태그 및 후속 정정의 범위는 각 원래 스펙을 따른다.

문서 검증은 ID·원앱 상태·false 보존, 파일/증거 해시 및 문서 범위만 검사한다. 제품 기능·SDK·실기기 검사 재실행이나 새 독립 제품 검수가 아니다. Pstack how 경로로 증거 계보를 대조하고 Ponytail 최소 충분성에 따라 기존 원장·영수증을 재사용했다. ARENA·순정 Goal은 사용하지 않았다.
