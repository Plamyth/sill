# iPad 입력 epoch 수정

작업 키 `ipad-input-epoch-20261025`, 기준 `e564f03c6206f192c84a1a2703d17d43c4ec70a8`.

기존 VisionInputBinding·VisionPresentation·VisionInputDebt와 SessionLink permit을 iOS에서 공유한다.
표시 티켓 하나의 peer·source·generation·videoEpoch로 입력을 캡처하고 실제 layer의 IDR·ready 전에는 거부한다.
표시·소스·연결·전경 경계는 대기 입력과 coalesced 이동을 취소하며 실제 전송 down만 기존 peer·binding으로 해제한다.
modern 관측 뒤 메타데이터가 없어지면 차단하고 기존 legacy 정책은 유지한다.

- [x] 실제 iOS 전송 경로의 실패 재현.
- [x] 공유 상태·미디어·hello·큐 취소 구현.
- [x] iPad·Vision·presentation·SessionLink 회귀 검사.
- [x] 부모 담당에게 수정·실행·미검증 근거와 SDK 준비 SHA 반환.

SDK·서명 빌드·설치·실물·독립 검수는 부모 담당 범위다. 이 검사에는 기기·실제 연결·권한·공유 Mac 조작이 없다.

## 적용 절차와 검증 범위

Pstack 버그 수정 경로에서 기존 호출자를 조사하고, 표시 허가의 누락을 기준 소스 실행으로 재현했다.
Ponytail의 기존 구조 재사용 순서에 따라 Vision의 binding·presentation·debt와 SessionLink를 공유한다.
새 프레임워크·의존성·타이머·Host 완화는 추가하지 않았다. 상태를 구조로 표현하고 원인을 공통 전송 경계에서 고쳤다.
ARENA·순정 Goal은 사용하지 않았다. SDK·실물 UI와 독립 검수는 부모 담당 범위이며 직접 커밋·PR을 만들지 않는다.

`python3 -B Tests/checks/ipad-input-epoch/run.py LABEL`은 실제 iOS sendInput·flush와 catalog·permit·취소 함수를 추출해 실행한다.
`--baseline`은 기준 커밋의 iOS sender가 표시 전 입력을 보내는 실패를 재현한다.
`--baseline-epoch`는 기준 sender의 실제 출력이 generation=A, videoEpoch=nil임을 보여준다.
`--reuse-modules PATH`는 동일한 기준 protocol과 Network 어댑터로 만든 기존 모듈을 사용한다.

`python3 -B Tests/checks/ipad-input-epoch/regressions.py vision LABEL MODULES`는 기존 Vision 입력 검사를 실행한다.
기존 fixture의 자동 소스 복구 부분은 현재 owner 계약 이전의 mock이어서 입력 검사에서 제외했다.
실제 자동 복구 블록은 기준 커밋과 동일함을 정적 검사하며, 새 자동 선택 동작을 검증했다고 주장하지 않는다.

`python3 -B Tests/checks/ipad-input-epoch/regressions.py presentation LABEL MODULES`는 기존 presentation-epoch의 codec·reader·표시 layer·client permit·미디어 수신 부분을 실행한다.
전체 Host 송신·geometry fixture는 새 HostLocalOwnerGrant·audio drain·catalog replay 보조 입력이 없어 컴파일 실패했다.
그 실패는 제품 red가 아니며 Host guard의 수정 근거로 사용하지 않는다. 부모의 설치 Host212 실제 계약 반례와도 구분한다.

`python3 -B Tests/checks/ipad-input-epoch/static.py`와 기존 `vision-input-controls/static.py`는 양쪽 hello·미디어 연결, iPad/iPhone project 참조와 Vision 표시 구현 동일성을 확인한다.
실제 UIKit·디코더·설치 Host·물리 기기 수용은 이 메모리 어댑터 실행으로 증명하지 않는다.

## 연결 대입의 스레드 조사

StreamClient 본체와 Home·Remote 확장의 대입을 조사했다. connect·adopt·disconnect·endSession, 자동 재연결·timeout·pairing 대입은 main 경로다.
아무 스레드에서나 호출되는 connectionLost는 fence 처리 뒤 실제 종료를 main에 전달한다.
새 iOS 교체 helper는 이를 가정하지 않고 SessionLink의 연결 교체·permit 폐쇄·old-peer 해제를 즉시 처리한다.
표시 상태 변경은 main으로 보내며 현재 peer를 다시 대조한다. queue.async로 강제한 비주 스레드 교체와 연속 교체 검사도 통과했다.
초기 green-regression-02의 마지막 FAIL은 queue.sync가 main에서 실행되어 테스트가 nil permit을 넘겼기 때문이었다.
이 시도는 동적 assertion 실패로 보존하며 컴파일 오류로 분류하지 않는다. 실제 비주 스레드와 이전 nonnil permit을 캡처한 green-regression-03이 수정 검증이다.

## 독립 검수 P2 수정

초기 30개 검사는 옛 종료 앞에 새 down이 존재하는 경우를 놓쳤다. debt만으로는 옛 종료와 새 down을 구분할 수 없었다.
P2 수정은 `captureInputSender`가 표시 binding·peer·permit을 캡처하고, 실제 UIKit producer가 그 closure를 시작부터 종료까지 보관하도록 했다.
Pencil은 UITouch identity, 인식기는 첫 touch 또는 began의 인식기 identity, hardware key는 UIPress identity를 사용한다.
같은 usage의 새 key가 시작된 뒤 옛 press가 종료되더라도 새 ForwardedKeys 소유권을 제거하지 않는다.
관성 callback도 시작 sender를 유지한다. 세로 trackpad는 재사용되는 UIView에 capture factory를 전달하고, 각 인식기·scroll·drag가 시작 sender를 끝까지 보관한다.
InputOverlay의 새 capture 인자는 optional 기본값을 유지하여 기존 Vision 호출 형식을 보존한다.
VisionInputSession·VisionPointer·Host·StreamProtocol의 제품 코드는 변경하지 않았다.

`producer.py`는 실제 touch began/moved/ended/cancelled·long-press·hardware forward·trackpad long-press 함수를 추출한다.
`--producer-baseline`은 기준 producer 함수를 사용한다. 수정된 공통 sender/debt만 둬도 `P2 실제 Pencil 옛 종료가 새 down 뒤 새 드래그를 해제하지 않음`에서 실제 FAIL을 재현했다.
`producer-red-02/1.log`는 이 제품 경로 red이며 `producer-green-02/1.log`는 동일 흐름과 새 종료의 정상 동작까지 39/39 통과한 green이다.
초기 producer fixture의 CGRect 초기화 컴파일 오류는 CoreGraphics import로 해결했으며 제품 red로 세지 않는다.

## 재사용 Trackpad의 관성·종료

`TrackpadView.updateUIView`가 `send`를 교체해도 진행 중인 flick은 `scrollSender`를 계속 사용한다.
`endScroll`의 begin·step·end callback은 같은 closure를 캡처한다. drag는 시작 인식기와 sender를 대조하고, tracker·pan 이동도 각각 자기 시작 scope를 사용한다.
SwiftUI identity 교체에 기대던 초기 방안은 제거했다. 새 timer나 producer 프레임워크는 추가하지 않았다.

`--trackpad-baseline`은 기준 Trackpad 함수를 현재 sender·실제 make/update 경로와 조합한다.
`trackpad-red-final`은 컴파일 성공 후 실제 `updateUIView` 뒤 옛 coast step 유출 assertion에서 실패했다.
`trackpad-green-final`은 44/44, 전후 소스 SHA 동일로 통과했다. 이 red/green은 동시 포인터 소유권 수정 전의 정확한 snapshot이다.

## 동일 epoch의 물리 포인터 소유권

독립 delta 검수에서 Pencil A와 indirect pointer B가 같은 버튼을 동시에 누르면 A의 종료가 B의 down까지 해제하는 기존 결함을 확인했다.
iOS는 기존 `pointerInputs`에 owner 한 개만 허용한다. owner가 끝나거나 취소되기 전에는 다른 touch의 down·move·up을 모두 무시한다.
혼합 touch 집합에서도 기록된 owner를 찾아 자기 down만 해제한다. 거부된 touch는 owner 종료 뒤 자동 승격하지 않고 새 touchesBegan만 허용한다.
Vision 분기는 기존 포인터 선택 방식을 유지한다. Host·debt 계약과 멀티포인터 프로토콜을 추가하지 않았다.

`pointer-owner-red`는 수정 전 실제 producer에서 두 번째 down과 선행 move 거부 assertion의 실행 실패를 기록한다.
이전 peer/epoch P2 검사는 새 overlay가 시작된 뒤 옛 overlay가 종료되는 경로를 유지한다.
같은 overlay에서는 epoch가 바뀌어도 기존 물리 owner의 종료까지 새 touch를 막는 별도 검사를 추가했다.
소프트웨어 키보드의 composed text는 기존 즉시 전송 모델을 유지하며, 큐에 든 문자의 binding 재캡처를 허용하지 않는다.

최종 앱 소스의 SDK 준비 표식과 파일 SHA는 `.build/checks/ipad-input-epoch/sdk-ready.json`에 기록한다.
이전 revision의 SDK PASS는 당시 snapshot의 결과이며 새 최종 SDK·서명·기기 수용은 부모 담당이 별도로 확인한다.

## 최종 실행 근거

최종 표식은 revision 4이며 `앱소스수정중지: true`와 앱 관련 파일 10개의 SHA를 포함한다.
`pointer-owner-green`은 58/58, 전후 소스 SHA 동일로 통과했다. owner 정상 종료·cancel·혼합 touch·거부한 touch의 가짜 up 없음·다음 새 touch와 secondary 버튼을 포함한다.
기존 Vision 101/101과 presentation 선택 범위 50/50은 최종 추출 manifest와 입력 전체가 동일함을 `regression-parity-r4.json`으로 확인해 재사용했다.

| 증거 디렉터리 | 컴파일 / 실행 | 판정 |
| --- | --- | --- |
| `red-baseline` | 0 / 1 | 기준 iOS sender의 표시 전 입력 전송 재현 |
| `red-missing-epoch` | 0 / 1 | 실제 출력 generation=A, videoEpoch=nil 재현 |
| `producer-red-02` | 0 / 1 | 옛 Pencil 종료가 새 down을 해제하는 P2 재현 |
| `trackpad-red-final` | 0 / 1 | 재사용 UIView의 옛 coast가 새 binding으로 전송되는 반례, SHA 불변 |
| `pointer-owner-red` | 0 / 1 | 같은 epoch의 두 번째 물리 포인터 down·move 허용 재현, SHA 불변 |
| `pointer-owner-green` | 0 / 0 | 최종 iPad 실제 함수 추출 58/58 |
| `signature-owner-final` | 0 / 0 | 기존 Vision InputOverlay·TrackpadView 호출 형식 2/2 |
| `vision-final` | 0 / 0 | 기존 Vision·SessionLink 입력 회귀 101/101 |
| `presentation-final` | 0 / 0 | 기존 codec·reader·표시·permit·미디어 선택 범위 50/50 |
| `final-static-r4` | 각 명령 0 | iPad 29, Vision 16, project plist lint, diff 공백 검사 |

모든 디렉터리는 `.build/checks/ipad-input-epoch/` 아래에 있다. 컴파일 실패와 사용하지 않은 반환값 warning은 제품 red로 계산하지 않았다.
수정 파일 목록·SHA·원래 red·설계·후속 경계는 같은 폴더의 `review-delta.json`으로 반환한다.
커밋·Host 쓰기·실기기 조작·설치·실제 네트워크 동작은 수행하지 않았다.
