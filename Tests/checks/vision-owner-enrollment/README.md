# Vision 코드 없는 등록 소비 검사

기준은 `ca716c3a6d068c90ddb1f7dc1610004261c6aebe`다. iPad `a7bc49211b3fa975d5261e07b1dd14aeea154ff9`의 상태머신·JSON·프로토콜·전체 검사 본문을 재사용했다. `upstream.json`은 원형 보존 해시를 고정한다. 저장소·전송 계층은 Vision 플랫폼을 추가하고 저장 namespace를 `dev.ambrion.SillVision.owner-enrollment.v1`로 분리한다.

`python3 Tests/checks/vision-owner-enrollment/run-mini.py`가 실제 재현 명령이다. 최소 입력을 연결된 SSD에 구성한 후 `mini-ephemeral-source`의 owner `01a13005-ff61-7780-b0e8-6dc171de1c9d`, job `vision-code-free-consumer-20261026`으로 실행한다. 종료 후 소스 전후 해시와 Mini 삭제 영수증을 확인한다. 결과는 storage-route가 확인한 `CCR-Vision/code-free-enrollment-20261026` 보관 폴더에 남긴다. 이 경로는 Git checkout 이전이나 source-guard verify 통과를 의미하지 않는다.

검사는 메모리 HTTP·소켓·기기 키·Keychain·시계를 사용한다. 실제 생산 상태머신과 `StreamClient+OwnerEnrollment`, `VisionControlEnrollmentController`, 이벤트 전송·구독 컨트롤러를 컴파일하고 호출한다. 플랫폼 import와 시계·시스템 I/O 경계만 격리한다. 새 인증 프로토콜은 없다. 등록 API는 기존 challenge, enroll, readback challenge, readback을 유지한다. Vision gateway 권한은 고정 origin의 `GET /v1/events`로 한정한다.

Vision 검사는 원본 iPad 검사에 창 lease·retire·scene·TLS peer·host pin·device pin·profile·취소·늦은 응답 반례를 추가한다. 401/403은 실제 HTTP 요청의 자격과 4096바이트 이하 JSON 본문을 전달한다. 갱신 중 epoch 변경과 반복 인증 실패는 재접속하지 않는다. 로컬 만료는 대화 화면이나 이벤트 401 없이도 자격당 한 번 예약한 타이머에서 기존 `ensure`를 재개한다. 현재성이 같고 서버 readback이 원 자격 만료를 확정한 경우에만 기존 `trustedRenew`가 한 번 실행된다.

첫 실행에서 옛 lease의 타이머가 새 lease로 재개하는 결함을 잡았다. 현재 타이머는 원 등록 인스턴스와 현재 TLS peer·lease·pin·기기 키·profile을 확인한 뒤 재개한다. 타이머가 중지되거나 신뢰가 바뀌면 새 등록과 저장은 없다.

이 검사는 Host232나 앱·화면·음성·실제 Keychain·기기·네트워크를 열지 않는다. SDK·서명·설치·실물 수용과 Host readiness는 부모의 별도 후속 단계다. bootstrap profile이 없는 패키지는 자동 등록을 거절한다. 코드 입력이나 다른 Mac 신뢰로 대체하지 않는다. 실제 profile 주입은 기존 `provision-owner-bootstrap.py`를 사용하는 부모 패키징 범위다.
