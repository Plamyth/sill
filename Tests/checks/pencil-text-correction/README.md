# Pencil 텍스트 교정 모델 검사

`python3 Tests/checks/pencil-text-correction/run.py`로 실행한다. Swift 컴파일러가 필요하다. `storage-route`가 외장 UUID와 경로를 검증한 뒤 지정된 `pencil-semantic-implementation-20261021/model-checks` 안에만 실행 파일, 모듈 캐시, 임시 파일과 영수증을 쓴다. 기존 `CanvasModel.swift`의 `canvasSelectedCharacterRange`를 그대로 추출해 함께 컴파일한다. UIKit, 기기, 개인 vault는 사용하지 않는다.

입력 좌표는 UITextView의 화면 point 단위이며 y가 아래로 증가한다. 호출자가 실제 layout에서 UTF-16 hit range를 계산한다. 삭제는 길이 있는 선택을 전체 Swift Character로 확대한다. 합치기와 나누기는 길이 0이고 Character 경계인 caret만 받는다. 합치기는 caret에 연속해서 닿아 있는 공백·줄바꿈 묶음 전체만 지우며 앞뒤 글자가 없는 구분자는 거부한다. 합치기의 삭제 대상은 모든 스칼라가 공백이어야 하므로 공백에 붙은 결합문자는 보존한다. 나누기는 양끝과 기존 공백 옆을 거부한다.

조절 임계치는 `gesture(for:)`에 모았다. 표본 4~4096개, 세로 길이 28pt 이상, 가로 폭은 12pt 및 세로 길이의 18% 이하, 시작·끝 세로 이동은 높이의 90% 이상이다. 세로 누적 이동은 순이동의 115%, 전체 경로는 125%까지 허용한다. 삭제는 폭 24pt 이상, 높이는 폭의 55% 이하, 누적 가로 이동은 폭의 3배 이상, 누적 세로 이동은 누적 가로의 50% 이하이고 좌우 반전이 3회 이상이어야 한다. 반전 하나는 8pt 및 폭의 45% 중 큰 거리 이상 움직여야 한다.

이 모델은 좌표 형태를 보수적으로 분류한다. 손글씨 인식기, MyScript 알고리즘 복제, 원본 잉크와 글자 대응을 제공하지 않는다. 실제 Pencil 표본의 압력·시간 정보가 없으므로 속도·기울기를 판단하지 않는다. 긴 일반 획도 같은 형태이면 분류될 수 있어 호출자가 교정 모드와 hit 대상을 확인해야 한다. 다중 획은 지원하지 않는다. Unicode 경계 검사는 텍스트를 한 번 순회한다. 실제 UI·Undo·저장·기기 수용은 부모 작업의 범위다.

Pstack Feature의 적용 기록은 다음과 같다.

- `how` over the affected subsystem. 기존 UTF-16 선택 확대와 UIKit 호출 경계를 읽어 재사용했다.
- `architect` for parallel design exploration. ARENA는 사용자 지시로 금지되어 지정된 계약을 그대로 사용했다.
- Blocking first steps. 기반 `db6eb823`, 쓰기 범위와 외장 경로를 확인했다.
- Independent workstreams. 부모는 `CanvasWorkspace.swift`, 이 작업은 교정 모델과 검사만 쓴다.
- Shared mutable state. 모델은 상태를 보관하지 않고 변경 범위와 대체 문자열만 반환한다.
- Smallest safe decomposition. 한 파일의 순수 모델과 같은 계약의 실행 검사로 제한했다.
- Delegate code-writing. 이 독립 작업이 모델 변경을 소유하며 부모가 별도 검수한다.
- Verify on the matching surface. Foundation/CoreGraphics 모델 실행으로 검증한다. 실제 UI는 미검증이다.
- Rebase into small, ordered commits. 사용자 지시로 commit·push는 하지 않는다.
- If the design is contested, interrogate before shipping. 계약은 사용자가 지정했고 출시는 하지 않는다.
- Run Opening a PR. 사용자 지시로 PR 작업은 하지 않는다.
- BLOCKED: independent review. 이 세션에는 하위 에이전트 도구가 없다. 자체 검사로 독립 검수를 대체하지 않으며 부모의 검수 결과를 기다린다.

Ponytail은 기존 선택 함수를 재사용하고 Foundation/CoreGraphics와 Python 표준 라이브러리만 쓰는 데 적용했다. 근거는 `myscript-pencil-gesture-stage-20261021/myscript-pencil-delete-join-split-spec.md`의 실제 scratch 삭제, 아래→위 합치기, 위→아래 나누기 관측이며 분류 임계치는 해당 앱에서 추출한 값이 아니다.
