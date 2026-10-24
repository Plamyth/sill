# SentryReturn v1 동결 계약

기준 a0b8e17, 작업 codex/sentry-remote-return-contract-20261025. 소유 범위는 SentryReturn DTO, StreamMessage의 223/224, 순수 SentryReturnAuthority와 이 검사 폴더다. Coordinator, Switcher, Model, Platform, 키체인, UI, 서비스와 실기기는 이 변경에 포함하지 않는다. 부모가 capability 삽입과 glue 및 최종 독립 검수를 소유한다. ARENA와 순정 Goal은 사용하지 않는다.

## 전송과 엄격한 제한

기존 14바이트 StreamMessage 헤더를 사용한다. 223은 client→host 요청이며 UTF-8 JSON 최대 4096바이트다. 224는 host→client 상태이며 최대 16384바이트다. 반대 방향은 -1로 거절한다. 213/214, 217/218, 219/220, 221/222를 재해석하지 않는다. capability 없는 호스트에 새 요청이나 213 false fallback을 보내지 않는다.

모든 객체의 필수 키 집합은 정확히 일치해야 한다. 중복 키와 Unicode escape로 철자만 바꾼 중복, 알 수 없는 키, 배열, 깊이 8 초과, 잘못된 타입을 거절한다. UUID는 소문자 표준 36문자, SHA256과 fingerprint는 소문자 hex 64문자, base64는 RFC4648 표준 alphabet과 필요한 padding을 갖는 canonical 표기만 허용한다. URL alphabet, 공백, 개행, 불필요한 padding과 padding 생략은 거절한다. nonce는32바이트/44문자, 공개키는 SPKI DER91바이트/124문자, 서명은 DER8~72바이트/최대96문자, signingPayload는 최대2048바이트다. capability의 독립 디코더 상한은 1024바이트다. 원본 요청 JSON의 공백과 키 순서는 자유지만 그 바이트를 그대로 보존해야 한다.

## JSON 형식

정확한 실행 가능한 JSON 문자열은 fixtures.json의 *Raw 값이다. fixtures.json 전체가 전송 envelope인 것은 아니다.

* request 및 keyEnrollment는 schemaVersion, operation, requestID, lease, authMode를 갖는다. lease에는 hostBootID, sessionID, revision, authorizationGeneration만 들어간다. keyEnrollment operation에만 keyEnrollment 객체를 추가한다.
* keyEnrollment.enroll은 action,keyID,publicKey만, rotate는 action,keyID,publicKey,previousKeyID만, revoke는 action,keyID만 갖는다. 세 작업 모두 authMode=macLocal만 허용한다. 첫 등록은 기존 키 부재, 회전은 기존 keyID 일치와 새 keyID, 해제는 현재 keyID 일치를 요구한다. 기존 TLS 키 자체를 인증 키로 자동 등록하지 않는다.
* current는 schemaVersion,operation,reference만 갖는다. reference에는 원래 requestID,hostBootID,requestDigest만 들어간다.
* cancel은 current 필드에 authGeneration을 추가한다. prove는 여기에 signature도 추가한다. prove에 success,accepted,authenticated 같은 bool을 넣지 않는다.
* 상태는 schemaVersion,reference,authGeneration,authStatus,operationState,code,challenge,remainingMilliseconds,currentProtection,nextPolicy를 항상 갖는다. 없는 authGeneration과 challenge는 null이다. challenge.keyID도 macLocal에서 명시적 null이다.
* capability는 schemaVersion=1,requestKind=223,stateKind=224,requestMaxBytes=4096,stateMaxBytes=16384,macLocal,deviceBoundKey,keyEnrollment="macLocalRequired"다. 뒤 두 bool은 현재 사용 가능 여부이며 OS 인증 성공 또는 하드웨어 attestation이 아니다. 키가 없으면 deviceBoundKey=false다. 부모는 WindowList 최상위 선택적 필드로 제공하며 기존 strict SentryState.control에 넣지 않는다.

## digest와 서명 바이트

requestDigest는 최초 request 또는 keyEnrollment의 정확한 UTF-8 payload 전체에 대한 SHA256 hex다. 다시 인코딩한 객체의 digest로 대체하지 않는다. 동일 requestID에 다른 바이트를 보내면 conflict다. current는 기존 결과를 읽을 뿐 인증·복귀·만료 연장을 일으키지 않는다.

서명 대상은 ASCII `ccr-sentry-local-return-v1`, NUL 한 바이트, 그리고 signingPayloadBase64 필드를 제외한 challenge 객체 전체의 UTF-8 JSON을 순서대로 이어 붙인 바이트다. challenge의 모든 깊이에서 키를 ASCII 사전순으로 정렬하고 공백·개행을 넣지 않는다. slash는 escape하지 않으며 문자열은 JSON 표준으로 escape한다. 모든 서명 필드는 ASCII이며 수치 필드나 배열은 없다. 호스트는 완성된 바이트를 challenge.signingPayloadBase64로 반환한다. 기기는 base64를 해제하고 purpose와 NUL, JSON tuple가 자기 요청 및 연결·키와 일치하는지 검증한 뒤 받은 바이트 그대로 서명한다. 기기에서 JSON을 다시 인코딩하여 서명하지 않는다. keyID=null도 포함한다. 추가적인 Unicode 정규화나 base64 decode 후 재정규화는 없다. challenge.reference의 digest가 원래 요청과 키 변경 내용을 결속한다. nonce는 호스트가 만든 32바이트 난수다.

서명 알고리즘은 ECDSA P-256/SHA256이다. Apple은 CryptoKit `signature(for: signingBytes)`와 DER representation, Android는 `SHA256withECDSA`에 동일 signingBytes를 입력한다. 이미 SHA256한 바이트를 SHA256withECDSA에 넣어 이중 해시하지 않는다. 서명 형식은 ASN.1 DER이며 raw r||s 64바이트가 아니다. publicKey는 P-256 SPKI DER91바이트를 표준 base64로 인코딩한다. Android X509 SPKI와 Apple CryptoKit derRepresentation을 사용한다. Swift X9.63 point65바이트와의 혼용은 거절한다.

fixtures.json의 signingPayloadBase64, signingBytesSHA256, proofRaw는 공통 golden이다. fixture의 키는 시험 전용 공개 테스트 scalar 1에서 생성했으며 실사용 identity가 아니다. 고정 proof는 실제 CryptoKit으로 검증한다. 이 proof가 userPresence나 키 ACL의 하드웨어 attestation을 증명하지는 않는다.

## 수명과 호출자 경계

authGeneration은 이번 인증 시도 UUID이고 authorizationGeneration은 기존 권한 세대다. 호스트의 monotonic 시간이 인증 최대120초와 복귀 최대30초의 권위다. wire에는 남은 milliseconds만 보낸다. 시간은 조회로 연장되지 않는다. nonce는 인증 성공 시 한 번 소비한다.

호스트는 ownerID, hostFingerprint, deviceFingerprint, 실제 TLS peer fingerprint, pairingGeneration과 lease를 연결의 현재 검증 결과로 제공해야 한다. 기기 fingerprint와 TLS fingerprint가 다르거나 페어링/owner 검증이 없는 연결은 거절한다. 키 등록·회전·해제는 이 동일 snapshot에 결속된 Mac LA ticket 완료만 수행한다. 새 앱·새 TLS identity·재페어링으로 기존 키 권한이 자동 확대되지 않는다.

authStatus와 operationState는 별개다. 인증 succeeded 후에도 복귀 failed/unknown이 가능하다. completed는 과거 작업 결과이며 현재 Sentry 보호 상태를 뜻하지 않는다. currentProtection="notObserved", nextPolicy="parentAdmissionRequired"는 항상 별도 필드로 반환하며 이 authority는 admission 수용을 주장하지 않는다. 동일 clientRunID의 자동 재접속 유지, 새 run/명시적 ON의 자동 보호 복귀는 부모 admission 계약과 수용 검사의 책임이다. 그 실제 관측은 부모의 별도 catalog/admission 필드로 연결한다. 부모는 최신 214/catalog 관측을 별도로 표시한다. 정상 completeLocalReturn의 Sentry 세션 reset 후에도 동일 owner/device/host/pairing identity는 과거 결과를 읽을 수 있다. 활성 작업의 세션 이동·lease 변경·장치 분리·취소·만료 뒤 오래된 증명은 거절한다. 다른 owner/device의 조회는 결과를 노출하지 않는다. authority 재시작은 unknown이며 자동 재실행하지 않는다.

## 검증

`python3 Tests/checks/sentry-return/run.py --evidence STORAGE_ROUTE_PATH --label UNIQUE_LABEL`로 실행한다. Mac mini의 작업 전용 한시 소스 사본에서 전체 생산 StreamProtocol과 순수 authority를 컴파일하고 검사한다. 사본 삭제 readback과 로컬 입력 해시를 함께 확인한다. 실제 UI/인증/HAL/기기 수용을 주장하지 않는다.

4617cd4의 최초 point/base64url 안내는 후속 SPKI DER/표준 base64/signingPayload 수정 커밋으로 대체한다. 부모는 이 최신 fixture hash로 기기 소비를 연결한다.
