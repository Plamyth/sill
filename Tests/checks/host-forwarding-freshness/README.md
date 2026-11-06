# 관측 응답의 직렬 큐 지연 회귀

`python3 Tests/checks/host-forwarding-freshness/run.py`

실제 `HostAudioForwardingRuntime`, `LocalAudioRelay`, 공용 프로토콜과 OS 파이프를 컴파일한다. 자식은 정확한 요청 외피를 검사하는 비활성 Python 피어다. 실제 Host/Core, 소켓, 오디오, 기기, 키, 권한 API는 사용하지 않는다. 기존 evidence-lifecycle 검사의 비활성 보호 경계와 native-relay-rpc-order의 검사 전용 접근자를 재사용한다.

연결을 한 번 등록한 뒤 FIFO의 앞선 요청과 각 응답에 550ms, 첫 byte와 나머지 JSON 개행 사이에 10ms를 둔다. 전체 JSON·개행·요청 상관·boot/PID·sequence 검증을 통과한 응답만 사용한다. 첫 byte만으로 성공을 만들지 않는다. 기준 소스는 `hold → forwardingConfigure → forwardingBootstrap → forwardingEvidence`에 약 2.28초가 걸려 두 개 검사가 먼저 실패했다. 후보는 `hold → forwardingBootstrap`으로 약 1.15초에 새 snapshot을 반환했다. 이는 격리 재현값이다.

별도 사례는 실제 런타임의 주기 renew와 observe를 겹친다. 주기 갱신은 계속 실행한다. 첫 지연 사례에서만 검사 전용 접근자로 대기 중인 polling task를 취소하여 FIFO 비용을 분리한다. 생산 코드의 poll 간격과 제한 시간은 바꾸지 않는다.

설정·credential·pairing 변경은 전체 등록으로 되돌아가야 한다. 큐 대기 중 권한·evidence 변경과 취소는 미송신으로 끝나고, 송신 후 설정 변경은 응답을 게시하거나 자동 재시도하지 않아야 한다. 잘못된 device와 3초가 지난 응답은 기존 경계에서 차단한다. 자식과 임시 입력은 검사 종료 시 정리한다.

이 검사는 Host245 로그의 매번 반복되는 등록 경로와 FIFO 증폭을 재현한다. 실제 Evidence 응답의 4.247초 지연 전체, 개행 도착 시점, MainActor 대기의 최초 원인 또는 실제 iPad 마이크 복구를 증명하지 않는다. 원본 first-chunk/max-hop 측정만으로 전체 JSON이 일찍 도착했다고 판단하지 않는다. 3초 안전 freshness, 현재 소유권·신뢰·Sentry 보호를 완화하지 않는다. 실제 설치와 기기 수용은 원 통합 담당의 별도 단계다.
