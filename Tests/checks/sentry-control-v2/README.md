# Sentry v2 계약 검사

production `SentryControlRequest`, `SentryControlResponse`, `SentryState`, `SentryAdmission`을 직접 컴파일하고 실행한다. macOS 14, iOS 17, visionOS 2.5 대상 SDK에서 공통 프로토콜과 Admission을 컴파일한다. 실제 Host, 입력, 기기, UI, 권한, HAL, 오디오, 서비스는 조작하지 않는다.

```sh
python3 -B Tests/checks/sentry-control-v2/run.py ARCHIVE_DIR ATTEMPT_NAME
python3 -B Tests/checks/sentry-control-v2/legacy.py ARCHIVE_DIR
```

`ARCHIVE_DIR`은 storage-route가 반환한 development-archive 경로다. 기존 영수증은 덮어쓰지 않는다. `run.py`는 `fixtures.json`의 원본문을 production parser로 소비하고 재생성한 fixture, 소스 해시, 명령 결과를 기록한다. `legacy.py`는 기존 Sentry 검사에 있는 OS 경계 주입을 재사용하며 실제 native panel 검사는 실행하지 않는다.

`request.schema.json`과 `response.schema.json`은 기기 소비자를 위한 JSON 구조다. byte 상한, 정수 토큰 형식, escape 해석 뒤 중복 키 거절은 production payload parser가 추가로 검사한다. v2 요청은 `SentryControlRequest(rawRequest:)`, v2 응답은 `SentryControlResponse.decodePayload`로 읽는다. 일반 `JSONDecoder`만 사용하면 중복 키 검사를 생략하게 된다.

멱등성의 기준은 immutable `rawRequest` 전체와 SHA256 `requestDigest`다. 재접속 시 이전 CAS를 현재 session으로 고치지 않는다. 현재 TLS의 같은 기기 지문과 같은 유효 generation이 확인된 후에만 기존 원본문의 기록을 읽는다. 원장에 없는 오래된 boot, session, revision은 `unknown/SENTRY_UNKNOWN`이다. 자동으로 새 requestID를 만들지 않는다. 최근 128개 작업만 보관하고 오래된 CAS는 재실행하지 않는다.

실제 on 표면 작업이 끝나지 않은 동안에는 `.pending`으로 실행 fence를 유지한다. 표면과 저장 상태가 확인되었으나 capture가 없으면 `.onPrepared(surfacesVerified: true)`로 정책을 확정하고 실행 fence를 해제한다. 소스를 고르기 전에도 새 off가 가능하다. 같은 정책에서 현재 capture가 확인되면 재조회 시 applied로 승격한다. 후속 명시 정책이 적용되면 superseded이다.

`VerifiedOwnerDevice`의 값 검사는 실제 TLS 또는 paired owner 검증을 수행하지 않는다. 실제 경로를 소유한 caller가 현재 암호화 TLS, admitted session, current paired owner fingerprint를 확인해야 한다. 기기 삭제, 회수, 재등록에는 `revokeControl`이 필요하다. `remove`는 연결 종료이며 동일 owner의 신뢰와 manual off를 회수하지 않는다.

수동 off는 화면 가림과 일반 로컬 입력 보호의 정책이다. 이 코드에는 오디오 credential, privacy journal, 오디오 복원, OS 로그인, TCC 승인 경로가 없다. 실제 curtain, tap, held-input readback과 TLS 배선은 부모가 담당한다. 이 검사 결과는 물리 클릭이나 설치된 앱의 수용이 아니다.
