# Ink undo 검증과 부모 전달

기준: `1d094a324888bd40c0f2e909aee62ecbf820667a`. 구현 소유 브랜치:
`codex/ipad-ink-undo-20261020`. 부모가 독립 검수와 기기 실행을 담당한다.

## 구현 경계

- `CanvasInkView.undoManager`는 해당 PKCanvasView 인스턴스의 전용 Foundation
  UndoManager를 반환한다. responder chain이나 UITextView의 manager를 가져오지 않는다.
- PencilKit이 등록한 action을 그대로 undo/redo한다. 제품에 drawing/scene snapshot
  history, 별도 action 등록, 외부 의존성을 추가하지 않는다.
- 그리기 delegate → `CanvasStore.updateDrawing` → 기존 autosave를 사용한다.
  노드·노트·에이전트 주석은 ink undo 대상에 포함하지 않는다.
- 외부 drawing 대입, import(같은 drawing 포함), 다른 scene ID, view teardown은 전용
  history를 비운다. generation/serial로 교체 전 대기 중이던 delegate 응답도 폐기한다.
  teardown에서는 외부 교체가 없을 때만 마지막 native drawing을 먼저 Store에 반영·저장한다.
- SDK의 `UIResponder.h`는 override 가능한 read-only `undoManager`를 선언한다.
  `PKCanvasView.h`는 tool begin/end와 drawing change delegate를 제공한다. drawing change는
  tool end 뒤에도 올 수 있어 availability는 group 완료와 drawing delegate 양쪽에서 갱신한다.
- `NSUndoManager.h`에 따라 nested group 중 명령을 막는다. `canRedo`는 checkpoint를
  발생시키므로 checkpoint는 관찰하지 않는다. group/undo/redo 알림만 비동기로 병합한다.

## 격리 macOS 실행 + iOS SDK 검사

저장 정책이 반환한 development archive 경로를 사용한다.

```sh
python3 Tests/checks/ink-undo/run.py ARCHIVE_OUTPUT
```

실제 production CanvasModel/CanvasStore와 Foundation UndoManager/PencilKit을 컴파일한다.
별도 HOME, CFFIXED_USER_HOME, TMPDIR, module cache를 사용하고 소스 전후 SHA를 기록한다.
macOS에서는 native PKDrawing의 async renderer를 PNG로 인코딩한다. iOS SDK에서는 실제
PencilCanvas coordinator와 SceneRenderer를 함께 typecheck한다. 앱/기기 실행은 하지 않는다.

검사는 **테스트 fixture가 명시적으로 등록한 action**을 이용한다. native mask의 undo/redo,
JSON visible intervals와 PKDrawing bytes, PNG, 저장/복원, 새 edit 뒤 redo 제거, 교체/import/
scene 전환, tool 중 disabled, nested groups, checkpoint 재귀, 독립 manager teardown을 확인한다.
이 결과는 실제 Pencil 제스처에 대해 PencilKit이 action을 등록했다는 증거가 아니다.

## 부모용 iOS helper

부모의 격리 진단 target에서 다음 파일들을 그대로 사용한다:

- `CanvasModel.swift`, `CanvasStore.swift`, `PencilCanvas.swift`, `SceneRenderer.swift`
- 이 폴더의 `InkUndoChecks.swift` (macOS용 `main.swift`는 제외)

진단 앱 bundle ID는 `.InkUndoCheck`로 끝나야 한다. 운영 iPad 앱의 bundle ID를 바꾸거나
운영 앱 컨테이너에서 이 helper를 실행하지 않는다. 설치/진단 방식은 부모가 결정한다.
진단 앱의 비어 있는 Application Support 경로를 명시적으로 전달한다:

```swift
let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
let result = try await InkUndoChecks.run(isolatedSupport: support)
```

iOS 분기는 실제 CanvasInkView/Coordinator를 통해 delegate → Store를 실행하고 production
`SceneRenderer.png`를 비교한다. 이전 delegate task와 import/dismantle의 경쟁도 검사한다.
여전히 action 등록은 controlled fixture이므로 아래의 실제 제스처 검증을 대체하지 않는다.

이 작업의 격리 macOS 결과는 undo 29/29, 기존 ink-visibility 277/277,
handwriting-race 18/18이다. iOS helper는 SDK 27 typecheck만 실행했다.
실제 iPad helper 실행, PencilKit의 제스처 action 등록, 버튼 UI 검증은 부모에게 남긴다.
로그·바이너리·소스 SHA 영수증은 소스 밖의 development archive에 보관한다.

## 부모가 남길 실제 iPad 증거

1. 실제 Pencil로 획을 그리고 부분 지우기. 그리기 중 두 버튼 disabled, 종료 후 가용 상태 확인.
2. “실행 취소”로 부분 지우기 전 잉크 복원 → “다시 실행”으로 지워진 구간 복원.
   JSON visible ranges, PKDrawing readback, production PNG가 각 상태와 일치하는지 확인.
3. undo 후 새 획을 그리면 redo가 사라지는지 확인. lasso 이동 및 whole-stroke eraser도 확인.
4. import/원격 장면 수신/다른 scene 전환 중·직후 이전 undo로 외부 변경을 되돌릴 수 없는지 확인.
   교체 도중의 실제 Pencil 압력 보정·취소 callback은 SDK typecheck로 증명되지 않는다.
5. 같은 화면 텍스트 편집 후 ink history를 비워도 텍스트 undo가 유지되는지 확인.
   VoiceOver 한국어 이름, 세로·가로·좁은 폭에서 두 버튼 터치 영역도 확인.

## Pstack checkpoint / Ponytail 선택

- [x] Blocking first steps: 기준 commit와 독립 worktree 확인, SDK header 및 기존 delegate/save 경로 확인.
- [x] Independent workstreams: n/a, native manager·delegate·toolbar는 한 lifecycle이며 fan-out 금지.
- [x] Shared mutable state: 전용 worktree만 쓰며 canonical/parent 소스는 수정하지 않는다.
- [x] Smallest safe decomposition: native manager와 가용 상태 controller, 기존 세 production 파일 재사용.

상위 절차는 Pstack feature. Ponytail은 플랫폼 기본 기능 재사용과 외부 교체 경계 최소 구현에
적용했다. ARENA는 사용자 지시로 사용하지 않는다. 검수 분리는 부모의 독립 review로 유지한다.
