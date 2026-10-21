# Swift 비공개 연결 근거 RPC와 Node 버전 고정

담당 대화는 `01a15bd5-2ed2-7bb0-9633-ce3d15de6be4`다. 작업 키와 브랜치는 `codex/host-evidence-rpc-20261021`이다.
기준 커밋은 `151a47702b50f7ceb586764c048e4ee839edd913`이며 시작 시 작업트리는 clean이었다.

- [x] Pstack `poteto-mode` 0.9.96의 Feature 경로로 기존 구조와 호출 경계를 확인했다.
- [x] `how`는 LocalAudioRelay의 진입 검사, FIFO, 송신 직전 admission, 응답 전달 검사를 순차 조사했다.
- [x] `architect`는 사용자가 지정한 메서드와 네 필드 구조를 채택했다. 사용자 지시에 따라 ARENA와 후보 경쟁을 실행하지 않았다.
- [x] Model the Domain 원칙으로 `AudioForwardingEvidenceOperation`과 내부 Encodable payload를 사용했다.
- [x] Ponytail `full`의 기존 코드 재사용 원칙으로 Bootstrap의 boot·membership 검사를 그대로 따랐다. 기존 메서드를 수정하거나 공통 호출부를 재작성하지 않았다.
- [x] 구현 담당은 지정된 단일 워크트리를 직접 수정한다. 이 세션에 `spawn_agent`는 없고 최종 독립 검수는 주담당과 호스트 원담당이 수행한다.
- [x] Blocking first steps. 기준 커밋·소유 브랜치·clean 상태와 검수 영수증을 먼저 확인했다.
- [x] Independent workstreams. 단일 RPC와 직접 회귀이므로 별도 구현 담당을 만들지 않았다.
- [x] Shared mutable state. 기존 MainActor와 FIFO를 사용하고 다른 워크트리·런타임·기기 상태는 변경하지 않았다.
- [x] Smallest safe decomposition. 동일 담당이 RPC, 세 곳의 Node pin, 16개 해시 목록과 직접 회귀를 하나의 변경으로 유지한다.
- [x] 정적 diff·Python 문법·허용 파일·해시와 기존 회귀 보존을 확인했다.
- [x] 소유 변경 파일을 확정했다. 최종 commit/tree는 커밋 후 Git readback으로 반환한다.
- [ ] 최종 독립 검수는 주담당과 호스트 원담당이 수행한다. 이 작업의 완료 판정에 포함하지 않는다.

Node 검수 정본은 `/Volumes/BT-Workspace/Development-Archives/control-room-mobile/shared-audio-live-evidence-20261021-reviewed.json`이다.
Node 후보 커밋은 `97f640bc6202a451b2211321aa96f20ee1a0f5ef`, 트리는 `c7147cbdfb506184dce2adbc86c46a7b1c4bee5a`이다.
검수 영수증의 16개 모듈 SHA와 Git 객체를 정적으로 대조한다. 후보 워크트리는 읽기만 한다.

실제 Swift·JVM·SDK 실행과 봉인 묶음 생성은 주담당 Mini 소유이므로 실행하지 않는다.
StreamServer, Coordinator, RemoteAccess, AppModel, HALFactory, 설치 앱과 기기를 변경하지 않는다.
새 메서드는 실제 비공개 제어 경로만을 위한 것이다. attach·renew 호출자는 Host context의 isCurrent를 순수 admission으로 전달하고, detach는 Host가 소유한 connectionID와 pairing 세대 권한으로 기본 admission 없이 호출할 수 있다.
테스트의 evidence 전용 strict allowlist는 `bootstrap`, `inspectRuntime`, `forwardingEvidence`, `hold`, `after-evidence`다. 기존 bootstrap·request allowlist와 검사 본문을 유지한다.
검증 결과는 정적 확인과 실제 실행을 구분하여 아래에 기록한다.

`/Users/ambrion/.codex/AGENTS.md`의 `ccr-system-coordination` 블록을 읽고 적용했다.
CCR 본체·접속기기·Sill·BT는 같은 연결 계약의 구성요소다. 사용자가 본체와 BT 실제 담당에게 Node 후보와 API를 전달했다는 사실을 수신했다. 이 작업에서 다른 담당에게 중복 전달하거나 서비스·기기를 조작하지 않았다.
이 작업은 Swift 비공개 API와 버전 고정의 소스 구현 상태다. 본체 통합, 메시지 접수 확인, 설치·실행 버전, 기기와 원격 상호작용의 실제 수용은 증명하지 않는다.

정적 검사 결과는 다음과 같다.

- `git diff --check`가 종료 코드 0으로 끝났다.
- Python `compile(..., 'exec')`로 `Scripts/package-local-audio-runtime.py`, `Tests/checks/native-relay-rpc-order/child.py`, `Tests/checks/native-relay-rpc-order/run.py`, `Tests/checks/relay-macho/closure.py`의 문법을 확인했다. 검사 대상 스크립트는 실행하지 않았으며 bytecode 파일도 생성하지 않았다.
- 새 enum과 `forwardingEvidence` 메서드를 제거한 relay 소스가 기준 커밋의 소스와 바이트 단위로 같았다. 새 evidence 검사와 진입 호출을 제거한 `Main.swift`도 기준 커밋과 바이트 단위로 같았다.
- 기존 child 함수와 bootstrap·request strict allowlist의 Python AST가 유지됐다. 사용자 인계의 기존 1601개 assertions에 대응하는 본문과 호출을 보존했으며, 이번 작업에서 실제 assertions 실행 수나 통과를 새로 주장하지 않는다.
- Node pin은 `LocalAudioRelayLaunch.swift`, 포장 스크립트, `closure.py` 세 곳에서 후보 커밋과 일치한다. closure 회귀는 후보 manifest를 요구하고 이전 pin `aa98e05842fccc034c1efd28461b489fe3d1a5b4`의 거절 사례를 추가했다. 기존 legacy pin 거절 사례도 보존했다.
- closure의 16개 모듈 목록과 SHA는 검수 영수증, 지정 Node 커밋의 Git 객체, clean 후보 워크트리의 실제 파일과 모두 같았다. 영수증 SHA-256은 `f0e68b049f7b950c3538800a81e5c5dafbf935e637a8d80c87931a73d0cead76`이다.
- 포장 스크립트는 pin 한 줄만 바뀌었다. exact-set 검사를 그대로 보존했다. Swift closure 검증 본문도 바이트 단위로 같고 모듈 SHA 세 항목만 갱신했다.
- 허용된 코드·직접 검사 8개 파일과 이 감사 파일만 변경했다. 보호 대상의 변경은 없다. 추가 코드 주석과 새 의존성은 없다. Pstack deslop 절차로 현재 diff를 직접 확인했으며 이를 독립 검수로 세지 않는다.

추가된 inert pipe 검사는 세 작업의 기본 admission과 명시적 admission, accepted·typed refused, 정확한 네 payload 키와 문자열 enum, 기존 네 키 snapshot, 연속 FIFO 순번을 확인하도록 작성했다.
세 작업 각각에 대해 진입 시 등록 boot·연결 boot·registry 교체·admission 거절·닫힌 객체를 검사한다. FIFO 대기와 응답 대기 각각에서 admission 철회·captured boot 교체·registered boot 교체·native membership 변경·relay registry 교체·동일 boot의 registry revision 교체를 검사한다.
낡은 호출은 nil을 반환하고 미전송 순번을 소비하지 않으며 현재 연결과 새 등록을 보존하는지 확인하도록 작성했다. 실행하지 않은 테스트의 동작을 통과로 기록하지 않는다.

미실행 항목은 Swift 빌드와 inert pipe 회귀 실행, JVM·SDK 검사, 포장과 봉인 묶음 생성, 설치, 실제 기기·원격 연동 수용, 최종 독립 검수다.
주담당 Mini에서 기존 전체 회귀와 새 `evidence` 선택 실행을 확인하고 주담당·호스트 원담당의 최종 독립 검수로 이어간다.
