# 펜 스타일 P2 복구의 자료형과 최소 설계

작업 키는 `ipad-ink-style-recovery-20261026`, 담당은 `01a17548-5c2e-7d51-9985-fba020c2b47e`다. 기준 HEAD는 `8a4298495935f72070c0762e7e583a53c413b236`, tree는 `c518d3af5e5da53ae44af42f3a701e43b65b3339`다. 전용 워크트리만 수정한다. 최초 작성자와 검수자의 자료는 읽기 전용 근거다. 릴레이 P1은 다른 담당의 소유다.

## 실행 흐름과 보존 조건

Store.updateDrawing은 저장할 PKDrawing 바이트를 다시 해독한 뒤 InkStroke 배열을 만든다. 기존 inkStyle은 inkType, 변환 가능한 sRGB 색, path-local size/opacity, transform을 생성한다. world points, native ID, 날짜와 mask visibility는 같은 원본에서 별도로 나온다. importScene과 restoreScene은 모양 검사와 native decode만 따로 수행하므로 두 데이터가 서로 다를 수 있다. CanvasPacket도 모양과 해시만 검사한다.

PencilCanvas.Coordinator의 tool-end와 비동기 drawing callback은 Store.updateDrawing의 false를 replaceDrawingFromStore로 처리한다. 이 함수는 undo 등록을 잠시 막고 실제 canvas.drawing을 대입한 다음 manager.removeAllActions를 호출한다. 외부 장면 교체에서는 history generation 변경과 전체 초기화가 의도된 동작이다. 로컬 실패에는 같은 초기화가 적절하지 않다.

## 자료형과 호출 계약

- 스타일 검증은 `CanvasScene`, `[InkStroke]`, `PKDrawing`을 그대로 사용한다. 새 포맷이나 의존성을 만들지 않는다. 기존 raw-native 투영과 inkStyle을 같은 공통 위치로 옮겨 writer와 검증기가 재사용한다.
- `CanvasScene.validateNativeInkProjection() throws`는 알려진 style이 있을 때 raw drawing에서 도출한 필드와 비교한다. style nil은 기존 unknown으로 보존한다. 변환할 수 없는 색 nil도 원래 뜻을 유지한다. native 바이트를 고치거나 투영으로 drawing을 재생성하지 않는다.
- Store import/restore 및 packet 생성/읽기에서 검증한다. 실패는 기존 장면과 native 원본을 보존하며 명시적인 오류를 반환한다. schema 2를 1로 낮추지 않는다.
- Undo 수리는 실제 PKCanvasView와 UndoManager를 화면 없이 실행할 수 있는지 먼저 확인한다. 단순히 removeAllActions만 생략한 방법은 setter와 기존 이력의 상호작용이 입증되기 전 채택하지 않는다. 필요하면 native 임시 이력과 Store가 수용한 drawing 전이 이력을 분리한다. 정확한 선택과 실행 근거를 구현 전에 여기에 추가한다.

## Undo 구현 전 결정

Mac Catalyst의 설치된 UIKit/PencilKit으로 창 없는 실제 PKCanvasView와 제품 Coordinator를 컴파일·실행했다. 실제 UndoManager 등록을 제어한 두 정상 편집 뒤 4 MiB 초과 편집을 거절하면 tool-end와 비동기 callback 양쪽에서 기존 undo 복원이 실패한다. 수정 전 `REJECTED_DRAWING_CHECKS total=18 failed=6`이다. native drawing setter에서 임의 이력만 제거하는 공개 API는 없다. 등록을 잠시 끄는 대입만으로는 거부된 편집의 기존 undo 항목을 제거하거나 기존 redo 분기를 보존할 수 없다.

`CanvasInkView`의 `inkUndoManager: UndoManager`는 수용된 `PKDrawing` 전이만 보관한다. `override undoManager`는 별도의 native 임시 manager를 반환한다. `Coordinator.commitDrawing(_:)`은 Store 수용 성공 뒤에만 이전 PKDrawing을 undo로 등록한다. undo/redo는 같은 등록 helper로 역전이를 기록하고 실제 canvas에 Store drawing을 복원한다. PKDrawing은 native 값 자체를 보관하며 투영으로 재생성하지 않는다. 로컬 복원은 native 임시 이력만 비우고 수용 이력을 유지한다. 외부 replace는 기존처럼 두 이력을 초기화한다. serial/generation/trace owner guard는 그대로 둔다.

같은 실제 canvas와 Coordinator의 검사를 수정 후 다시 실행한다. 이 검사는 센서가 만든 내부 등록을 관측한 시험이 아니라 native 등록을 제어한 실제 객체 상호작용 시험이다. 실제 Pencil 수용과 구분한다.

## 확인된 결과와 남은 범위

스타일 반례는 61개 중 55개 실패에서 0개 실패로 바뀌었다. 실제 canvas 반례는 최초 18개 중 6개 실패를 재현했고, 최종 36개 전부 통과했다. 최종 검사는 tool-end, 비동기 callback, background flush, 거절 뒤 기존 undo·redo와 기존 redo 분기, 실제 renderer의 거짓 투영 거부, 외부 import의 이력 초기화를 포함한다. 기존 실제 Coordinator 회귀 38개도 통과했다.

기존 검수자의 `NativeProjectionReadCounterexample.swift`를 수정하지 않고 현재 제품 소스로 다시 컴파일·실행했다. importScene에서 `unsupportedInkProjection`을 반환하므로 예전의 거짓 style 저장·재열기·패킷 주장이 더 이상 성립하지 않는다. 실행은 이 담당이 수행했으며 기존 검수자가 새 CLEAR 판정을 반환했다는 뜻이 아니다.

Mini의 SDK 26/PencilKit에는 native ID API가 없었다. 로컬 SDK 27의 PencilKit overlay 버전 616을 실제 swiftinterface에서 확인하고 `canImport(PencilKit, _version: 616)`으로 경계를 표현했다. 구형 overlay에서 known style 검증은 명시적으로 거부한다. Mini의 순수 모델 네 묶음은 통과했고 입력 SHA와 한시 경로 삭제 영수증을 확인했다. 이는 codex-source-guard로 같은 작업의 전체 실행 이전을 수용했다는 뜻이 아니다.

actual ObsidianVault 파일 왕복 48개와 iOS SDK 27의 CanvasBridge·관련 audio helper typecheck가 통과했다. native transform 52개, mask visibility 277개도 통과했다. 알려진 deprecated API 경고는 기존 `UIScreen.main`과 `installTap`이며 이 작업에서 새로 도입한 API가 아니다. 정확한 최종 HEAD/tree, 검사 입력 SHA와 외장 결과는 반환 report.md/result.json에 기록한다.

새 독립 검수는 실행하지 않았다. 사용자가 중첩 agent를 금지했고 이전 검수자는 종료된 상태다. Pstack poteto-mode의 “A review gate stays closed when no independent reviewer can run.”에 따라 자체 검사를 독립 CLEAR로 바꾸지 않으며 mergeReady와 shipping은 닫는다. 검수된 결과의 통합과 기기 검증은 부모에게 반환한다. 시스템 키보드 responder 경로·실제 Pencil 센서·실기기·설치·공유 Host 수용은 미검증이다. 릴레이 P1은 편집하지 않았고 전체 제품 기능 완료·원앱 동등성을 주장하지 않는다.

## 절차와 범위

Pstack Bug fix/TDD/how/architect와 Model the Domain을 적용한다. Ponytail full의 기존 helper와 표준 native 기능 재사용을 선택한다. ARENA와 중첩 agent는 사용자 지시로 실행하지 않는다. 새로운 독립 검수자 판정은 부모가 별도 확인해야 하며 자체 검사로 대신하지 않는다.

순수 모델 검사는 Mini의 작업 전용 한시 입력과 해시·삭제 확인을 사용한다. native/SDK 검사는 Mac의 설치된 SDK와 외장 전용 출력만 사용한다. 두 영역은 병렬 검사할 수 있고 같은 소스 변경은 직렬로 수행한다. 병목은 플랫폼 native 실행 가능성과 실제 undo setter 동작이다. 기기·시뮬레이터 부팅·Host·UI·서명·설치·음성·외부 네트워크 효과는 범위 밖이다.
