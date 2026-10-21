# 인증된 로컬 오디오 복귀 요청

지원하는 정식 `/Applications/CCR Sill.app`에서만 제공한다. 설치된142에는 아직 없다. 알림은 인증 요청이며 인증 결과나 복귀 성공을 전달하는 명령이 아니다.

## 지원 조회

UserDefaults 도메인 `com.ambrion.sillcanvas.mac`의 `CCRLocalAudioReturnSupport.v1`을 읽는다. `version=1`, `hostBootID`, `hostPID`, `requestNotification`, `resultsKey`가 있다. 실행 중인 PID의 경로·bundle ID·기존 지정 서명 요구사항을 대조한다. 과거 프로세스의 지원 기록을 현재 지원으로 취급하지 않는다.

## 요청

`DistributedNotificationCenter`에 이름 `com.ambrion.ccrsill.requestAuthenticatedLocalAudioReturn.v1`, object는 대문자 canonical UUID 문자열, userInfo는 nil로 보낸다. 예를 들어 Foundation의 `UUID().uuidString`을 사용한다. 별도 인증 결과·PIN·암호·HAL 설정값은 전달하지 않는다.

한 번 발급한 UUID는 재전송에도 유지한다. 같은 부팅에서 이미 기록한 UUID는 다시 인증하거나 복귀하지 않는다. 다른 요청을 처리 중이면 새 UUID에 blocked 결과를 남긴다. 상단바 버튼도 동일한 인증·복귀 함수를 호출한다.

## 결과 조회

같은 도메인의 `CCRLocalAudioReturnResults.v1`은 UUID 문자열을 키로 하는 사전이다. 최근32개를 유지한다.

| 필드 | 의미 |
| --- | --- |
| version | 1 |
| hostBootID, hostPID | 해당 실행 세대 |
| requestID | 요청한 canonical UUID |
| phase | authenticating, restored, blocked |
| restored | 실제 인증·참여자 종료·HAL 복원 확인을 마친 경우만 true |
| observedAt | Unix 초 |
| completedAt | 최종 상태에만 존재하는 Unix 초 |
| reason | 실패·거절의 한국어 설명, 선택값 |

호출자는 요청 UUID, 현재 지원 정보의 부팅ID와 PID, 실행 중 canonical 앱의 서명을 모두 대조한다. authenticating, 기록 부재·탈락, 프로세스 종료, 저장 실패, 다른 부팅의 결과는 성공이 아니다. 기본설정 파일은 로컬 상태 전달 수단이며 다른 프로세스가 보낸 임의 알림을 인증 증명으로 사용하지 않는다. 원격 단말의 인증·보호 증명은 기존 TLS 연결과217/218 계약을 계속 사용한다.

복귀는 Host 자체 LocalAuthentication, native/relay/Node 전체 quiesce·inspect, 실제 HAL 복원과 상태 readback을 거친다. 원격 연결이 끊기거나 상태 조회가 실패했다고 로컬 오디오를 자동 복원하지 않는다.
