# 재사용한 iPad 등록 검사

원본은 iPad 정본 `a7bc49211b3fa975d5261e07b1dd14aeea154ff9`다. 상태머신·JSON·프로토콜과 전체 검사 본문은 그대로 재사용한다. Vision 작업의 Mini 진입점과 설명만 현재 담당 경로로 바꿨다.

Vision 전체 검사는 `python3 Tests/checks/vision-owner-enrollment/run-mini.py`로 실행한다. `iOSClient/Tests/owner-enrollment/run-mini.py`도 같은 진입점을 사용한다. 직접 `run.py`는 iPad 어댑터 모드의 메모리 검사를 실행한다. 실제 HTTP·소켓·Keychain·기기 키·앱은 사용하지 않는다.

Vision 전용 검사와 범위는 `Tests/checks/vision-owner-enrollment/README.md`에 있다. 이식 원본의 과거 SDK·독립 검수는 이번 Vision SDK·실기기 수용을 대신하지 않는다.
