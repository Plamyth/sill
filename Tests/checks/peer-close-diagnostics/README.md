# 연결 종료 진단 검사

`bash Tests/checks/peer-close-diagnostics/run.sh`

최초 전송 오류가 뒤따르는 수신·정리 오류로 바뀌지 않는지, 종료 후 늦게 도착한 전송 오류가 이전 Client를 유지하지 않고 기록되는지, 연결별 값과 읽기/큐/처리 byte 단계를 분리하는지 검사한다. 출력은 연결당 최초 실패와 종료 각1회로 한정한다. payload·엔드포인트·키·토큰·화면·오류 설명은 진단 객체의 입력이 아니다.

실제 `StreamServer`의 헤더·payload 수신 진입부와 직접 tick·pointer·goodbye 전송 콜백을 추출해 함께 컴파일한다. 데이터와 오류가 동시에 도착하는 경우 및 연결 정리 뒤 늦은 직접 전송 오류를 재현한다. 전체 프로토콜·실제 NWConnection의 연결 수명은 SDK 빌드와 독립 소스 검수로 별도 확인하며 이 부분 대역 검사를 실제 네트워크 수용으로 확대하지 않는다.

`read_bytes`는 프레이밍을 포함해 Network에서 읽힌 byte, `queued_bytes`는 `NWConnection.send`에 넘긴 byte, `processed_bytes`는 오류 없는 `.contentProcessed`가 반환된 byte다. 클라이언트 수신·렌더 ACK 또는 통신사 과금 byte가 아니다. 종료 뒤 콜백이 올 수 있으므로 종료 로그의 값은 해당 시각 표본이며 최종 합계라고 보장하지 않는다. `tx_kind`는 presentation adaptation 전 source kind다.

Host 연결·허용·취소·오디오·Sentry·인증·재시도 정책은 바꾸지 않는다. 이 검사나 SDK 빌드는 실제 무선 영상·입력 성공, 기존 SocketException 원인 규명 또는 설치 수용이 아니다.
