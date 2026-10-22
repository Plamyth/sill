# Vision 독립 스트림 소비 회귀 검사

`python3 Tests/checks/vision-peer-scope/run.py`로 실행합니다. 실제 `StreamClient` 명령·메뉴·선택·표시 콜백과 `MacMenuElements.deferred`를 추출하고, 실제 DTO·메뉴 상태·입력 binding·SessionLink·모니터 상태 모델을 사용합니다. Network와 UIKit 어댑터는 메모리 대역입니다.

- 표시 전 명령, 다른 epoch, 반쪽 메뉴 응답, 오래된 행, 재접속 및 legacy 전환을 거절합니다.
- 행의 원래 응답 범위와 실제 표시 허가를 유지하며, 취소된 전송의 재등장을 막습니다.
- 표시 전 fetch 거절은 해당 대기만 종료하고 최상단 구독은 보존합니다.
- 같은 창·모니터·현재 앱 재선택에는 revision/epoch 변경을 요구하지 않습니다. 다른 선택이 대기 중이면 대상이 일치하는 새 관측이 필요합니다.
- 최상단의 실제 deferred provider와 기존 legacy 제목 재탐색도 실행합니다.
- 기존 메뉴 상태 무작위 검사도 함께 실행합니다.

`--no-op-only`는 동일 창 재선택 반례만 좁게 실행합니다. 부모 지적 반영 전 두 반례의 실패 로그는 작업트리 밖의 담당 증거 폴더에 보존합니다.

실제 Mac, 네트워크 연결, 디스플레이, 디코더, UI, 오디오, 설치 또는 기기 수용을 증명하는 검사가 아닙니다. Mini 실행은 원담당 owner를 유지한 `mini-ephemeral-source` 경로를 사용하고 삭제 확인 영수증을 별도로 확인합니다.
