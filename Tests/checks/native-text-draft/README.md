# Native text draft checks

The parent runs `python3 -B Tests/checks/native-text-draft/run.py ROOT OUTPUT` with absolute paths. OUTPUT must be outside ROOT. The runner emits `RESULT_JSON` and an isolated `result.json`. It compiles production `SessionLink`, the separate pure draft model, and the actual extracted StreamClient boundary against inert Network and SwiftUI adapters. It does not instantiate UIKit or send network traffic.

Run the existing controls and presentation suites as well. Their extractors and source lists include the new model. The controls suite retains its original `remote.py` and `mini.py` entry points. The presentation suite accepts `python3 -B Tests/checks/presentation-epoch/run.py ROOT OUTPUT`.

Runtime cases cover ticket ownership, cancellation before asynchronous enqueue, held and fenced per-message counts, peer/permit/catalog refusal, terminal callbacks and lock reentry, actual send/cancel races, foreground loss on a legacy host, route start, scope replacement, duplicate requests, weak client ownership, and frozen editor generations. Text checks exercise exact UTF8, Korean composition refusal, observed Dictation ambiguity, controls, newline separators, Character/byte/cluster bounds, and explicit recovery. UIKit hooks and project membership have static source contracts. The product SDK build remains a parent-owned gate.

Each mutant must match every anchor once, compile successfully, and exit with exactly its named runtime failure. A compiler error, timeout, or unrelated failure is not a kill. Failures retain bounded diagnostics in `RESULT_JSON` so the parent can preserve evidence after removing remote temporary output.

This suite cannot establish physical Dictation callback ordering, system Voice Control behavior, microphone state, text-field focus, CGEvent handling by a destination application, or host acceptance. A submitted ticket means only that its existing input message was handed to Network.send. No test text is persisted by the product.

배치 회귀 검사는 실제 `VisionInputSession`, 초안 모델, 전송 경로와 부모의 범위 변경·초안 닫기 함수를 사용합니다. 전송 콜백 전후의 로컬 화면 크기 변경을 주입해 초안과 전송 확인 상태가 유지되는지 검사합니다. 레거시·화면 세대 연결과 장면 비활성화, 포인터가 활성인 동안의 입력 취소를 함께 확인합니다. `DraftWorkspace`는 SwiftUI의 알림과 화면을 실행하지 않으며, 범위 변경 알림을 명시적으로 호출합니다. 이 검사는 xrOS의 실제 배치 변화나 시트 표시, native UI 테스트 통과를 증명하지 않습니다.
