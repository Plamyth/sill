# Vision 센츄리 v2 소비자

기준 becd0641d1f67b6f722db672088ed36aa02e02c1 / da3e1e91fcd8e4233ebee114b78c25c3899aecfa.
작업 키 vision-sentry-control-v2-20261025. 이 별도 워크트리만 수정한다.
원 담당 대화는 01a16f03-b6ba-7372-ade0-a335c0609df9다. Mini 실행 영수증의 owner는 같은 작업의 안정 별칭 vision-sentry-control-v2-20261025이며 이 대화에 대응한다.

- [x] 1. `how` over the affected subsystem.
- [x] 2. `architect` for parallel design exploration.
  - skip: 사용자 ARENA 금지. 기존 컨트롤러·SessionLink·보호 저장 패턴을 재사용하는 직접 설계로 대체한다.
- [x] 3. Write the throughput checkpoint as four todo items.
  - Blocking first steps. 기준 clean/원격 HEAD/tree, DTO 출처, 저장 경로를 확인했다.
  - Independent workstreams. DTO/fixture 대조와 기존 소비자·신뢰·저장 경로 조사는 독립 읽기로 진행했다.
  - Shared mutable state. 새 브랜치·워크트리 전용 쓰기. Host213, 기기, 앱, 오디오, 공유 서비스에는 쓰지 않는다.
  - Smallest safe decomposition. 연결·원문·상태 전이가 결합된 소비자 구현은 한 작성자가 소유한다. spawn_agent 도구가 없어 위임하지 않으며 독립 검수는 부모에 반환한다.
- [x] 4. Delegate code-writing to a subagent using your configured feature model.
  - skip: 이 세션에 spawn_agent가 없다. 직접 작성하고 독립 검수는 부모 담당이 소유한다.
- [x] 5. Verify on the matching surface.
  - 비활성 Network·저장소 소비자 검사, 공유 fixture, 기존 v1 회귀, visionOS SDK 빌드. UI 실물 수용은 미검증.
- [x] 6. Rebase into small, ordered commits. Stack follow-ups.
  - 단일 사용자 지정 기준의 한 소비자 변경으로 scoped commit을 만든다. 공식 integration에 rebase·병합하는 단계는 부모 소유다.
- [x] 7. If the design is contested, `interrogate` before shipping.
  - n/a: DTO 계약과 재사용 범위가 사용자 지시로 고정됐다.
- [x] 8. Run **Opening a PR**.
  - skip: PR·공식 통합·설치·실행은 사용자 지정 부모 담당 소유다.

## 예상 변경 파일

- Sources/StreamProtocol/Sentry.swift, SentryControl.swift. Host exact e17ec2abec7d9ea47b6262531674fc17fe22c6af DTO만 의미 대조해 포트한다.
- Tests/checks/sentry-control-v2/{fixtures.json,request.schema.json,response.schema.json}. 같은 커밋의 공유 계약만 포트한다.
- visionOSClient/VisionSentryController.swift. 기존 v1 유지, v2 요청·재조회·결과 상태를 확장한다.
- visionOSClient/VisionSentryRequestStore.swift. 기존 보호 저장 API의 클로저·Keychain 패턴을 재사용한다. credential 전용 API에는 원문을 넣지 않는다.
- visionOSClient/StreamClient+VisionSentry.swift, iOSClient/StreamClient.swift. 현재 TLS 신뢰 binding과 기존 SessionLink에 연결한다.
- visionOSClient/SillVisionApp.swift. 한국어 켜기·끄기·수동 원문 재조회와 분리 안내를 제공한다.
- Scripts/make-vision-project.py, SillVision.xcodeproj/project.pbxproj. 새 저장 파일 membership만 반영한다.
- Tests/checks/vision-sentry/{run.py,Standins.swift}. v1 회귀의 DTO 의존성과 inert 저장을 반영한다.
- Tests/checks/vision-sentry-v2/{main.swift,run.py,README.md}. 실제 소비자와 adapter를 inert로 검증한다.
- 기존 소비자 회귀 runner의 명시적 DTO 컴파일 목록은 SentryControl 의존성이 생긴 곳만 보정한다.
- iOSClient/SessionLink.swift. 마지막 Network.send 직전의 선택적 isCurrent 검사를 추가한다. 기본값은 기존 동작이며 센츄리 v2만 현재 TLS 공개 binding 검사를 전달한다. 큐 보류 중의 로컬 신뢰·지문 철회를 재검증하기 위해 필요하다.

## 구조와 수용 기준

컨트롤러가 catalog와 현재 TLS Mac ID·지문·기기 지문 binding을 소유한다. 저장 record는 binding과 immutable 7필드 rawRequest를 가진다. boot·authorizationGeneration은 rawRequest와 현재 capability를 대조한다. 원문을 전송 전에 보호 저장하고 readback으로 같은 바이트를 확인한다. 재접속·재실행은 수동 재조회만 허용하며 session/revision을 고치지 않는다. 새 boot·기기·철회·세대 변경·저장 실패는 실행을 차단한다.

accepted는 Host 수락 여부이고 applied와 별개다. pending·applied·rejected·superseded·unknown을 보존한다. pending on 뒤 명시 off는 허용하고 기존 원문 재조회는 별도다. 네트워크 재접속이나 catalog 수신은 자동 toggle을 발행하지 않는다. 오디오 복귀·OS 로그인·TCC는 원격 보호 off와 분리한다.

## 검수 경계

2026-10-25 후속 canonical 정책을 수용했다. 원문별 ledgerAccepted를 Host accepted=true 응답으로만 영속 저장한다. saved-only·송신 미확인·응답 미확인은 같은 session에서 재전송하지 않는다. 같은 device·boot·auth generation에서 새 sessionID를 받은 뒤에만 옛 CAS 원문을 수동 조회한다. accepted=true rejected는 접수 확인과 적용 거절을 구분한다. Host/wire/querykind와 미확인 명령 재실행 UI는 추가하지 않는다.

독립 검수 도구가 없어 Pstack 독립 검수는 부모 반환 시 BLOCKED로 기록한다. 자체 검사와 SDK 컴파일을 독립 검수나 실기기 수용으로 보고하지 않는다.

## 최종 작성자 검증

- Mini의 별도 임시 입력에서 실제 소비자 156개, 기존 v1 80개, 화면 선택 173개와 테스트 대상 회귀가 통과했다. 네 suite 모두 sourceUnchanged와 최종 소스 파일 SHA256 대조가 true다. 테스트 Network·저장소는 비활성이다.
- 맥북의 기존 Xcode에서 Release arm64 visionOS SDK xros27.0 빌드가 통과했다. Mini에는 CommandLineTools만 있으므로 SDK 빌드만 맥북에서 실행했다. 앱 실행·설치·실물 수용은 하지 않았다.
- DTO 두 파일·공유 fixture/schema 세 파일은 Host 지정 commit과 byte 일치한다. unknown capability의 v1 on-only 호환은 Vision catalog 수신 경계에서 처리한다. Host 생산 소스는 포트하지 않았다.
- canonical 접수 표시, saved-only·전송 전 중단·send 실패·무응답의 같은 session 조회 금지, 새 session의 옛 CAS 원문, accepted=true rejected와 eviction unknown, 최종 송신 binding 재확인을 검사했다.
- Mini 영수증의 cleanup_verified=true를 확인했다. 첫 후속 회귀 시도의 SSH 255와 삭제 확인은 이력으로 보존했다. 같은 실패를 반복 성공으로 바꾸지 않았다.
- 증거 경로는 /Volumes/BT-Workspace/Development-Archives/CCR-Vision/vision-sentry-control-v2-20261025다. 최종 consumer·SDK 영수증과 handoff.json이 정확한 commit/tree에 연결된다.
- BLOCKED: independent review. spawn_agent·독립 리뷰 도구가 없는 이 writer는 독립 검수를 주장하지 않는다. 부모는 이 diff의 독립 검수와 실제 Host 계약 수렴·PR·통합·설치·앱 실행을 소유한다.
- ARENA·순정 Goal, 실제 UI/streamMac 제어, OS 인증·TCC·페어링·recognitionKey·오디오 credential·Host213·HAL·공유 서비스 변경은 0이다.
