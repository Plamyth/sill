# 네이티브 캔버스 모드 수명 검사

부모 담당이 설치하는 격리 검사 앱에서 실행한다. 일반 사용자 앱이나 실제 vault로 실행하지 않는다.

`CanvasModeLifetimeChecks.swift`를 현재 CanvasBridge 소스와 함께 `DEBUG`, `CANVAS_MODE_LIFETIME_CHECK` 정의로 빌드하면 전용 SwiftUI 앱 진입점이 포함된다. 기존 격리 runtime의 정확한 commit/tree 메타데이터와 context를 준비하고 `--ccr-test-runtime ID`로 시작한다. 검사 파일은 일반 앱 target에 추가하지 않는다.

전용 앱을 대상으로 UI 검사 runner에 `CCR_MODE_LIFETIME_PROBE=1`을 전달하고 `CanvasBridgeUITests/testNativeModeLifetimeProbe`를 선택 실행하면 화면의 `CANVAS_MODE_LIFETIME total=… failed=0` 결과를 확인한다. 일반 격리 앱에서는 `testModeSwitchHidesOriginalInputAndAccessibility`로 모드별 접근성과 노드 화면 좌표를 확인한다. 두 검사는 서로 다른 앱 빌드를 대상으로 하므로 각각 선택 실행한다.

네이티브 검사는 실제 `UIHostingController`, `UISegmentedControl`, `PKCanvasView`, `UndoManager`를 사용한다. 원본·다이어그램·분할 모드를 반복 전환하면서 객체 동일성, Undo·Redo 그림 반영, 숨겨진 캔버스의 터치 차단, 뷰포트·줌·노드 좌표 보존을 확인한다. 실제 scene 교체와 뷰 제거에서는 이력이 지워지는지도 확인한다. Undo 등록은 제어된 검사 입력이며 실제 Pencil 입력 증거는 아니다.

코드 작성자는 `Tests/checks/pele-live/run.py OUTPUT --review-fix`로 모델·Store·잉크 이력을 실행하고 네이티브 검사와 UI 검사를 iOS SDK로 타입 검사한다. 이 명령은 앱을 설치하거나 네이티브 모드 검사를 실행하지 않는다. 실제 캔버스 수명과 접근성 수용은 부모의 설치 후 실행 결과로 기록한다.
