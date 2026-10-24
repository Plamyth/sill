# iPad owner receipt 소비 검사

원담당은 `01a13ace-e372-7ed1-9946-149df37ee1c3`이다. 기준 소스는 `dce769525e4fa53651abcca52d1f9ea98c9e3d29`다. 구현과 커밋은 이 작업의 단일 작성자가 소유하고 SDK 검사와 독립 검수는 부모가 이어간다.

검사는 다음 명령으로 실행한다.

```sh
python3 iOSClient/Tests/owner-enrollment/run-mini.py
python3 iOSClient/Tests/owner-enrollment/run-mini.py --bootstrap
```

`run-mini.py`는 지정된 워크트리의 부모 폴더 안에서 최소 입력을 구성한다. `mini-ephemeral-source`의 owner와 job은 각각 위 원담당 ID와 `ipad-owner-receipt`로 고정한다. 전후 파일 SHA는 `.audit/ipad-owner-receipt-pure-input.json`, 결과와 Mini 삭제 영수증은 `.audit/ipad-owner-receipt-pure-result.log`에 남긴다. 원격 입력은 종료 후 제거한다. 이 검사는 Git checkout 이전이나 `codex-source-guard verify` 통과를 주장하지 않는 독립 메모리 검사다.

`run.py`는 Foundation·CryptoKit의 실제 JSON·P256 검증, 생산 등록 상태머신, 실제 socket exchange와 Keychain adapter 메서드를 실행한다. HTTP·소켓·서명·저장·시계는 메모리 대역이다. `StreamClient+OwnerEnrollment.swift`는 파일 그대로 가져오며 플랫폼 import와 시계 경계만 메모리 환경으로 바꾼다. Security의 저장 함수와 기기 서명 함수는 대역이며 실제 Keychain·기기 키 생성·TLS·HTTP·앱·UI·음성은 실행하지 않는다. 공개 합성 fixture 외에 일회성 메모리 P256 Host 키로 정상 서명의 잘못된 payload를 검사한다. 확정 갱신 왕복에는 합성 Host·모형 기기의 메모리 키를 사용한다. 이 테스트 키는 내보내거나 저장하지 않는다.

생산 시작 지점은 인증된 `markConnected`, `remoteSessionReady`, foreground 복귀, 인증된 연결 이동 완료다. 현재 peer·saved trust·서명된 앱의 owner profile·자체 기존 키가 모두 일치해야 시작한다. background, 현재 연결 유실·교체, 저장 신뢰 변경, `tearDown`에서 취소한다. `connected`나 기존 연결 문구를 등록 결과로 바꾸지 않는다.

원문 enroll body와 원 challenge·binding·정규화 digest는 송신 전에 한 Keychain 항목에 CAS 저장하고 다시 읽는다. 성공 후에도 원 pending을 보존하여 같은 credential을 읽을 수 있다. 응답 유실 시 유효한 원문만 재전송하며, 만료 또는 readback 요구 뒤에는 같은 원 작업의 새 nonce에 서명한다. 정확한 readback 401 `CREDENTIAL_EXPIRED`만 원 pending과 credential을 이력으로 옮긴다. `resumeOwnerEnrollment`와 보호 API 거절 wrapper는 archive CAS 저장·readback 성공과 동일한 현재 신뢰를 확인한 뒤, 그 요청 안에서 `trustedRenew`를 한 번 호출한다. 사용자 버튼·로그인·페어링을 요구하지 않는다. 갱신 완료 callback을 같은 재개 경로로 되돌리지 않아 루프를 만들지 않는다. 손상·미확인·신뢰 거절은 자동 초기화하지 않는다.

현재 cached 자격의 정확한 401·신뢰 거절 403은 저장소를 읽기 전에 메모리에서 격리한다. load·CAS·후속 readback 실패 뒤에도 그 token hash와 terminal 거절을 유지한다. 늦은 옛 401·403은 새 cached 자격을 거절하지 않는다. `StreamClient`는 binding별 거절 상태를 앱 메모리에 보존하므로 foreground·재연결로 등록 소비자가 교체되어도 저장된 옛 grant를 다시 수용하지 않는다. 거절 이력의 실제 Keychain 내구성과 앱 프로세스 종료 뒤 동작은 실기기 수용 범위다.

`ownerEnrollmentCredential`과 `ownerEnrollmentAuthorizedRequest`는 별도 자기 기기 자격을 제공한다. 후자는 고정 origin의 허용된 GET·POST 경로에만 Bearer를 넣고 현재 신뢰·binding·만료·epoch를 검사한다. 보호 API의 거절은 실제 그 요청에 쓴 credential을 `ownerEnrollmentUnauthorized`에 전달한다. CanvasRelay·Sill TLS·오디오 credential·lease는 이 경로에 포함하지 않는다. 보호 API 전체 UI 이관은 범위 밖이다.

## 계약과 fixture 출처

Host 공식 소스는 `6d3118d348d6c2abcb03411dd763ad2d12407405`의 `MobileEnrollment.swift`, `OwnerEnrollmentRequest.swift`, `Remote.swift`다. iOS 소비자는 Host만 아는 node expiry나 ownerPrincipal을 만들어 `ReceiptInput`에 넣지 않는다. 기존 신뢰 pin으로 원 payload 서명을 검증하고 공개된 challenge·기기·origin·시간·ownerPrincipal 형식을 결속한다. 공통 파일·Host 앱·vision 코드는 바꾸지 않는다.

Android 정본은 `Plamyth/ccr-android`의 `fe6198d57ba1d6f6884401e4e5a0028617d32cd1`이다. `DeviceEnrollmentProtocol`, `DeviceEnrollmentProof`, `DeviceRegistration`, `SillOwnerExchange`와 서버 네 파일을 대조했다. gateway 보호 경로는 같은 소스의 `server/control-room-server.js` 계약을 따른다. Core 참고 소스는 `284f5975c4a6c75fab6faf8fde136196a6940438`의 host adapter와 command gateway다. 이 소스는 현재 listener의 준비 상태를 뜻하지 않는다.

복사한 fixture는 위 Android commit의 `tests/fixtures`에 있는 공개 합성 자료다. 실행 전 SHA256을 확인한다.

| 파일 | SHA256 |
| --- | --- |
| `device-enrollment-golden-v2.json` | `12c3fdf84163ed9407f5b82bb10c96baa3fda387b93870f5fe49023d3bdef059` |
| `device-enrollment-readback-golden.json` | `2b7064d3a2fd50e1f79b4dfdc5744aee1caf1b911e63a4599b287daf168b695a` |

readback 원문 정규화 digest는 `27dc24fd08d264847e1c5efa8a2d71ed9b81057953417b162aa61e745010b776`이다. 원문 문자열의 단순 SHA와 구별한다. 이 검사는 실제 SDK·실기기·실제 credential 발급·네트워크·Keychain 내구성 수용을 대신하지 않는다.
