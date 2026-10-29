# 지도와 개요의 같은 원본 사용

기준은 정확 `7db3b835073c0c7d275078d8f8a765af3ca2ac5f`다. 원 초점 WT는 읽기 전용으로 보존하고 별도 `hierarchy-outline-product-20261029/source` / `codex/ipad-hierarchy-outline-product-20261029`에서 Store/Workspace의 개요 범위만 소유한다.

## 관측과 구현 경계

R077의 `rea-stage1-20261021/margin-branch-observed-spec.md`는 MarginNote Mac4.4.6의 같은 카드 ID·접힘 공유·개요 들여쓰기·뷰 재진입·Undo/Redo 관측이다. 원앱 iPad/Pencil/앱 프로세스 재시작 또는 깊이별 일괄 접기를 입증하지 않는다. 원앱 Group의 ZTYPE256/ZMINDLINKS/ZMINDCLOSE를 CCR 메타데이터에 그대로 이식하지 않는다.

CCR 개요는 기존 보이는 node ID와 깊이·접힘 표시만 계산한다. 일반 `parentChild`의 순서는 원래 link 배열을, 그룹은 기존 `CanvasGroup.Entry.memberIDs`의 순서를 사용한다. 새 scene·영속 트리·DB는 없다. 초점/태그/열린 그룹 투영에서 숨은 부모는 목록에 추가하지 않으며, 보이는 자손은 현재 범위의 최상위 행으로 표시한다. 이는 필터 표시 규칙이며 원래 부모를 바꾸지 않는다.

원앱 Group 전체 의미와 직접 대응하지 않는 범위가 있다. CCR 그룹은 기존 annotation/general-link 소유 표식과 순서 계약이며 일반 `parentChild`로 변환하지 않는다. 그룹 행은 `toggleGroup`, 일반 행은 `toggleChildren`을 각자 사용한다. 기존 계약이 허용하지 않는 중첩/관계나 손상 표식은 개요에서 명시 거부하며 데이터가 없는 것으로 간주해 고치지 않는다. 새 그룹 의미·source metadata·서버/문서 wire는 추가하지 않는다.

## 원본·입력·저장

- 지도/개요는 같은 `selectedNode`와 원래 `isCollapsed`를 사용한다. 전환은 원문 revision·접힘·선택 ID·입력 모드를 바꾸지 않는다. 지도 복귀는 기존 원본/다이어그램/나란히 선택도 유지한다.
- 일반 지도 접기에 없던 Undo 기록은 두 보기 공통의 `persistScene(next)` 성공→설치→`recordGraphEdit` 경로에 연결했다. 그룹은 기존 경로 그대로다. 접힘만 달라진 그래프 이력인지 기존 snapshot bytes로 구분해 두 보기에서 입력 모드를 임의 변경하지 않고 같은 Undo/Redo를 사용한다. 프로세스 재열기의 원문/접힘 확인과 같은 실행의 Undo/Redo 확인을 구분하며, 새 영속 Undo 저장소는 만들지 않는다.
- 보기 선호도만 기존 `CanvasRuntime.Defaults`의 `canvas.hierarchyPresentation.v1` key에 `map`/`outline`으로 둔다. 초점 설정 key와 형식을 재사용하거나 수정하지 않는다. 존재/타입/UTF8 값을 대조해 미존재와 외부 dictionary·숫자 값을 혼동하지 않는다. 확인할 수 없는 설정은 덮지 않는다. 정상 앱 UserDefaults의 실제 디스크 내구성은 미수용이다.
- row 명령은 기존 문서/page/scene/selection/view owner를 재사용한다. 보기 왕복은 view generation을 올려 같은 화면·같은 카드로 돌아와도 과거 callback을 거부한다. IME/노트·주석/잉크/드래그·저장 중에는 원래 입력을 바꾸지 않는다.
- 개요의 자유 잉크는 표시/선택/그리기에서 가리고 원본 PKDrawing·UndoManager 이력을 유지한다. 초점과 개요가 기존 native command gate를 공유한다. 카드/일반 링크/주석/native ink/원문참조는 전체 canonical Document/scene에 남으며 Files와 AI packet은 전체 원본을 사용한다.

## 기존 초점 수리와의 의존

Planck의 `hierarchy-focus-independent-review-7db3b835/REVIEW.md`가 찾은 초점 key의 미존재→외부 dictionary 덮어쓰기 P2는 부모가 e73 합본 WT에서 수리한다. 이 WT는 그 초점 설정 비교를 수정/복제하지 않는다. 새 개요 key에는 존재/타입을 구분하는 별도 최소 확인만 사용한다. 최종 공식 통합은 부모의 해당 수리와 의미 결합해야 하며, 이 branch 전체가 기존 초점 P2까지 해소했다고 주장하지 않는다.

## 검증 절차

Pstack how/feature로 기존 투영·group membership·접기·원본 저장·input owner를 대조하고 Ponytail은 기존 Store/defaults/Undo/visibility 재사용에 적용했다. 사용 가능한 spawn_agent가 없어 원담당 직접 구현이며 자기 검증을 독립 수용으로 세지 않는다.

- Blocking first steps: 기준/별도 WT/소유 파일과 R077 관측을 확인했다.
- Independent workstreams: 원 초점 Planck 검수·부모 초점 P2 수리·다른 원담당 EPUB/HTTP는 그대로 독립 진행한다.
- Shared mutable state: 이 WT의 Store/Workspace 개요 구간만 단일 writer가 쓰며 공식 통합은 부모 소유다.
- Smallest safe decomposition: 목록·선택·접기·Undo·표시 투영의 하나의 공통 원문 경계를 묶어 검사한다. 모델/서버/DB/앱/서비스를 추가하지 않는다.

`Tests/checks/hierarchy-outline/run.py --output <storage-route 외장 경로>`는 실제 Store·PKDrawing·격리 preferences·전체 Document Files와 자체 Markdown 파일을 사용한다. 원문 수정 callback은 실제 자체 파일을 읽지만 HTTP/서버 관측은 아니다. `--sdk-only`는 통과한 native를 반복하지 않고 전체 iOS27 Store/Workspace typecheck만 수행한다. GUI/기기/설치/Host/질문/알림/키/권한/ARENA/Goal/loop0, 실제 UIKit·원앱 iPad 수용은 false다.

## 실제 native 결과

`evidence/outline-5c8cf12e-a781-49ae-b1e4-1a78f68f757b/result.json`·`observations.json`에 실제 Store/PKDrawing/격리 preferences/자체 Markdown/전체 Document Files의 compile/native exit0과 입력·normal sentinel 불변을 기록했다. 별도 프로세스 재열기는 legacy1회와 Document1회다. 보기는 같은 카드 ID·원본 접힘을 공유하고 일반 가지/그룹 각각의 Undo/Redo, 보기/페이지 ABA, 입력 busy 거부, 초점/태그/열린 그룹 범위, 실제 원문 참조 갱신/Files 역수신, hidden 데이터·AI packet 전체 직렬화를 확인했다. 미존재 key 뒤 외부 dictionary/숫자가 생긴 반례도 각각 원문·설정 bytes를 보존했다. revision 소진은 public 내부 편집 입력의 거부 반례이며 실제 외부 Files가 그 값을 수용했다는 뜻이 아니다.

첫 실행 `outline-0236707a-d8d1-41d7-b507-b52427b7cf34`는 태그 API가 요구하는 `#읽기` 대신 `읽기`를 넘긴 fixture 기대 오류로 중단했다. 제품 tag validator를 바꾸지 않고 fixture만 수정했으며 실패 영수증도 보존했다. 통과 뒤 현재 범위가 빈 개요의 한국어 안내를 추가했으므로 그 UI 한 줄은 native 행동 실행의 근거로 세지 않고 최종 SDK 범위로 확인한다.

## iOS27 SDK

`evidence/outline-6e4196a9-c634-4c56-8c9c-e9293640e1f6/result.json`에서 제품 commit `ce7d652470f2d11415243213bd20ac529c0d80ab` / tree `9fa08c46bba5a465109eb91a19f5f2bcd2d72e9c`의 plist·iOS StreamProtocol·전체 Store/Workspace typecheck가 모두 exit0이었다. 입력 전후 SHA·normal sentinel은 같았고 native를 다시 실행하지 않은 `--sdk-only` 결과다. 기존 installTap/UIScreen.main deprecation 경고는 이 단위에서 수정하지 않았다. 이 영수증 연결 후속은 문서만 바꾸며 제품 bytes는 같다. 독립 source 검수·부모 초점 P2 수리와의 통합·실제 UIKit/iPad 수용은 남아 있다.
