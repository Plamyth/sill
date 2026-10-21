# HostAudioForwardingRuntime 작업 기록

- 작업 키는 host-audio-runtime-20261021이다. 기준은 6292c2e6bccbd452fe4f4653d2c3446e78d54009이며 전용 브랜치와 워크트리만 쓴다.
- 소유 범위는 새 runtime, Tests/checks/host-audio-runtime, 이 기록과 LocalAudioRelay.stop() 하나다.
- [x] Ground / how. 실제 relay FIFO, participant ticket, coordinator의 25초 소비, privacy/sentry readback과 context의 요청·연결 수명을 확인했다.
- [x] Sketch / model-the-domain. MainActor의 UUID별 ConnectionLease에 주체·관측 credential·설정·renew 시각·작업을 모은다. 긴 reconcile과 1초 관측 및 5초 renew는 별개다.
- [x] Agree. 사용자 지정 구조와 기존 Coordinator/Participants/Protection을 직접 재사용한다. ARENA와 후보 경쟁은 실행하지 않는다.
- [x] Blocking first steps. 전용 HEAD/clean 상태와 파일 소유권을 먼저 확인했다. 부모의 추가 spawn은 전역 thread limit로 실패했으므로 추가 생성하지 않는다.
- [x] Independent workstreams. n/a. runtime과 회귀는 같은 계약을 공유하므로 이 담당이 순차 작성한다. 부모는 다른 파일에서 통합한다.
- [x] Shared mutable state. UUID별 lease와 relay 소유 lifecycle을 분리한다. 요청 취소를 공유 relay RPC 취소로 전달하지 않는다.
- [x] Smallest safe decomposition. 이 작업자는 독점 워크트리에서 구현한다. OS/HAL/process만 fixture로 대체하고 production 증명 모델은 유지한다.
- [x] Implement 체크포인트. production runtime 및 전용 source runner의 현재 작성분을 보존한다. 실행 수용은 미완료다.
- [x] Scrap 검토 기록. 기존 구조를 직접 재사용했으며 새 의존성을 추가하지 않았다. 아래 API 한계를 미해결로 남긴다.
- [ ] 실행 검증. Swift 문법·타입·링크·동작, Mini 회귀와 전체 SDK는 모두 미실행이다.
- [ ] 독립 검수. 부모 통합 검수 전에는 완료·수용으로 간주하지 않는다.
- [x] 인계 기록. 사용자 최종 지시로 구현과 시나리오 추가를 중단한다. 지정 파일만 체크포인트 커밋한 뒤 HEAD/tree를 최종 응답으로 전달하고 쓰기를 부모에게 반납한다.

## 기존 API 경계

forwardingConfigure(privacyGeneration:)와 forwardingDisconnect(_:)에는 FIFO 대기 후 송신 직전 caller의 lifecycle을 재검증하는 admission 인자가 없다. 엄격한 송신 직전 계약에는 각각 admission: (@MainActor () -> Bool)?가 필요하다. 이 작업의 LocalAudioRelay 수정 권한은 stop() 하나뿐이므로 해당 API는 바꾸지 않는다. configure 중에는 configuration admission을 닫고 전후 설정을 검사하며 disconnect는 정확한 bindingEpoch에만 적용한다. 이 한계는 부모에게 즉시 보고했다. 기존 API로 해당 두 송신 자체를 취소할 수 있다고 주장하지 않는다.

## 검증 및 수용 경계

실제 HAL·기기·Orca·서비스 조작은 하지 않는다. 새 모델 heartbeat나 외부 의존성을 만들지 않는다. source runner는 실제 runtime·relay·Coordinator·Participants·Protection·Privacy·Sentry를 컴파일하며 OS/process의 fixture는 실제 음원을 다루지 않는다. 실행 전인 검사는 통과로 기록하지 않는다.

## 현재 체크포인트와 미확인 항목

- 생성자는 부모가 수용한 init(privacy:sentry:prepareProtection:)으로 작성했다. 콜백은 실제 보호 readback이 없는 새 quiescing binding에서만 호출한다. 콜백 이후 generation/config가 바뀌면 이전 binding을 소비하지 않는다. 기존 두 인자 생성자의 overload는 없다.
- 부모가 privacy/sentry 무효화 관찰자, connectionClosed, 전체 앱 stop과 생성자 호출부를 통합해야 한다. 이 담당은 AppModel/StreamCoordinator/StreamServer/HAL/Sentry 소스를 수정하지 않았다.
- 런타임·검사 Swift 파일의 문법, 타입 추론, MainActor 결합, 실제 relay FIFO 동작은 컴파일·실행으로 확인하지 않았다. 회귀의 지연 대기와 fixture 시작 동기화도 미실행 상태다.
- Python AST 정적 검사에서 당시 child.py와 run.py가 파싱됐다. 이후 run.py의 선택적 출력 경로와 임시 출력 정리를 수정했으며 그 최종본은 재실행하지 않았다.
- 실패한 최초 observe의 provisional attach는 같은 evidence 세대만 detach하고 성공 observation 없는 lease는 renew하지 않게 작성했다. 재observe 실패의 이전 성공 lease 보존, arm 뒤 새 configure/binding 수렴, 보호 불가 catalog와 commit 거절은 검사 소스로만 작성했으며 통과 증거는 없다.
- source runner는 인자 없이 실행할 수 있다. 부모의 준비된 launch-host-audio-runtime-checks-20261021.py가 이 호출을 사용할 수 있다. 이 담당은 해당 실행기를 읽기만 했으며 실행하지 않았다.
- Swift 빌드·전용 회귀·Mini·전체 SDK·실기기·서비스/HAL 실행은 모두 0회다. 이 커밋은 검증 전 체크포인트이며 merge-ready 또는 실제 HAL 수용을 의미하지 않는다.
