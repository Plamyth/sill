# 홈 리스너 자동 복구 후보

기준은 `91bcbbe8affd3e07a041dc4312ac902f550b03c4`다. 현재 Host off의 원인을 고쳤다는 주장이 아니며 설치·공식 통합은 부모 검수 뒤 별도로 판단한다.

Pstack how로 기존 네트워크 큐와 Direct Wireless 교체 흐름을 추적했고 architect에서 같은 교체 경로를 재사용하도록 정했다. ARENA는 사용자 금지에 따라 실행하지 않았다. Ponytail은 별도 런타임이나 리스너 추상화 대신 작은 순수 상태와 기존 메서드를 선택하는 데 적용했다. 독립 검수는 부모가 소유한다.

`HomeListenerRecovery`는 idle, running, replacing, waiting(ticket), stopped 상태를 가진다. 실패 예약은 한 개이며 2, 5, 15, 30초로 증가한 뒤30초를 유지한다. ready는 실패 횟수를 초기화한다. retry ticket은 한 번만 소비하고 stop은 종료 상태다. 네트워크 큐에서만 접근한다.

`StreamServer`는 실패한 홈 리스너의 마지막 정상 포트를 기억하고 기존 취소·교체·광고 경로로 복구한다. 복구 중 포트 충돌은 다른 포트로 우회하지 않는다. 설정 변경은 기존 교체 동작을 유지하며 진행 중 변경은 최신 원하는 설정으로 수렴한다. NWPathMonitor는 같은 큐에서 불통에서 정상으로 바뀐 경우에만 대기 중 복구를 앞당긴다. 별도 daemon이나 모델 루프는 없다. quit의 goodbyeAll이 복구와 새 접속을 먼저 중단하고 기존 연결의 종료 메시지는 그대로 보낸다.

검사는 실제 StreamServer의 수명주기 메서드를 추출하고 접근 제한 및 작업 항목 타입만 바꿔 가짜 큐·시계·리스너로 실행한다. 실제 Network listener, Host 앱, 기기, 오디오, HTTP는 실행하지 않는다. 순수 상태 외에도 실패 후 실제 교체 메서드 실행, 같은 포트, 오래된 콜백, 지연된 취소, 설정 수렴, 네트워크 복귀와 수동 종료를 검사한다. 변이 검사는 복구 누락·이전 리스너 상태 수용·포트 변경·종료 무효화를 각각 검출해야 한다. shutdown 진입점, CLI exit, TLS와 loopback 팩토리 경계는 별도 정적 검사다.

Mini 한시 실행 사본 안에서 다음을 실행한다. 출력 경로와 복사본 전체는 실행 후 공식 ephemeral 도구가 제거하고 표준 출력·삭제 확인 영수증은 맥북 연결 SSD의 원담당 로그에 보존한다.

```sh
python3 Tests/checks/home-listener-recovery/run.py --output .verification/home-listener --mutants --sdk-build
```

SDK 검사는 SillHostCore만 컴파일하며 실행하거나 링크된 Host 앱을 시작하지 않는다. 기존 전체 소스의 오류로 실패하면 그 실패를 별도 보고하며 결정적 검사를 실제 설치 수용으로 확대하지 않는다.
