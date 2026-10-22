# Pencil 텍스트 교정 모델 검사

부모 담당이 exact source에서 `python3 Tests/checks/pencil-text-correction/run.py`를 실행한다. 이 구현 자식은 빌드와 검사를 실행하지 않는다. 기본 출력은 지정 worktree 안의 `.build/pencil-text-correction-checks`다. 다른 영수증 위치가 필요하면 `--output 절대경로`를 전달한다. `storage-route`로 확인한 BT_CCR-ipad 외장 경로 안에서만 출력한다. Swift 컴파일러가 필요하며 UIKit·기기·개인 vault는 사용하지 않는다.

`CanvasModel.swift`의 실제 `canvasSelectedCharacterRange`와 실제 교정 모델을 함께 컴파일한다. 원문 전후 해시와 컴파일·실행 종료 코드를 result.json에 남긴다. Character 전체 삭제, 같은 줄 공백 합치기, 나누기, 수동 선택 교정, 원문 UTF8·세션·선택 snapshot을 검사한다.

입력 좌표는 y가 아래로 증가하는 UITextView point 단위다. 위로 곧게 그은 획은 합치기, 아래로 곧게 그은 획은 나누기다. 삭제는 선택 범위를 전체 Swift Character로 확대한다. 합치기와 나누기는 Character 경계인 길이 0의 caret을 받는다. 합치기는 양옆에 비공백 글자가 있는 연속 U+0020만 제거한다. 줄바꿈·문단·Markdown hard break·탭·NBSP·그 밖의 Unicode 공백과 공백에 붙은 결합문자를 보존한다. 나누기는 글자 사이에 공백 하나만 삽입한다. 양끝·기존 공백 옆·글자 내부는 거부한다.

수동 교정은 선택 범위가 전체 Character 경계일 때만 변경을 반환한다. 빈 대체 문자열·같은 UTF8 문자열·잘못된 범위는 변경하지 않는다. 사용자가 명시한 NFC/NFD 변경은 허용하지만 snapshot 동일성은 정규화하지 않고 UTF8로 비교한다.

실제 UIKit 검사는 `Tests/integration/ipad-runtime/CanvasBridge/PencilTextCorrectionChecks.swift`에 있다. `Tests/checks/native-ink-rendering/ProbeApp.swift`는 잉크 PNG 검사용이므로 이 변경에 포함하지 않는다. UIKit 검사는 공백 중앙 영역과 실제 caret mapping, 합치기·나누기·교정 Undo/Redo, 원문·선택·세션 변경, 취소·중복 확정·IME·Scribble 보호, 실제 교정 입력창, 원문·연결 문단의 기존 Store CAS와 저장·재열기를 검사한다. 합성 획 또는 수집 좌표 replay이며 실제 Pencil 센서 재주입이 아니다.

모델과 Coordinator는 손글씨 인식 후보를 생성하지 않는다. iOS 기본 Scribble와 UIKit 편집메뉴를 유지한다. 선택 교정 창은 직접 입력이나 OS가 지원하는 손글씨 입력을 받으며 사용자가 적용을 눌러야 원문을 바꾼다. MyScript 후보나 인식 알고리즘을 구현한 것으로 표시하지 않는다.

이번 작업은 Pstack Feature 경로를 적용했다. 원문·연결 문단·노드가 동일 VaultMarkdownEditor를 사용함을 확인했다. 사용자 지정 데이터형 CanvasPencilTextChange와 기존 UIKit replace·Undo·Store CAS를 재사용했다. ARENA와 순정 Goal은 실행하지 않았다. 구현은 전용 worktree 한 곳에서 소유하며 부모가 exact commit의 빌드·검사·독립 검수·실물 수용을 소유한다. Ponytail full에 따라 새 인식기·의존성·저장 경로·동기화 계약을 만들지 않았다.
