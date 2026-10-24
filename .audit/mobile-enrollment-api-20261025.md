# 모바일 자동등록 순수 계약의 호출 API

원담당은 `01a13005-ff61-7780-b0e8-6dc171de1c9d`다. 기준 commit은 `e9c556f8cd610414df7340074ed30073e9f11fec`, tree는 `d2e2016387127da8298c2a1a154c6b3224fedfba`다. 이 writer의 독립 검수·push·PR·통합·설치는 부모 소유다.

계약 정본은 `/Volumes/BT-Workspace/Development-Archives/ccr/ccr-local-only-input-20261025/mobile-enrollment-contract.json`과 같은 대화에서 추가 확정한 duplex 필드·digest 배열이다. HTTP 처리와 TLS kind 19/20은 구현하지 않는다.

공개 API는 `StreamProtocol.MobileEnrollment`에 모인다.

```swift
HostProfile(macID: String, trustedFingerprint: String, publicSPKIDER: Data) throws
InitialChallenge(challengeId: String, nonce: String, deviceId: String,
                 origin: String, expiresAtMilliseconds: Int64) throws
ReceiptInput(host: HostProfile, challenge: InitialChallenge,
             devicePublicSPKIDER: Data, socketDeviceFingerprint: String,
             ownerPrincipal: String, nowMilliseconds: Int64,
             nodeExpiresAtSeconds: Int64) throws
ReceiptInput.payload() throws -> Payload
Envelope.decode(Data) throws -> Envelope
Envelope.parts() throws -> (payload: Data, signature: Data, spki: Data)
verifyReceipt(Envelope, expected: ReceiptInput, nowMilliseconds: Int64) throws -> VerifiedReceipt
VerifiedReceipt.deviceProofBytes: Data
VerifiedReceipt.verifyDeviceProof(signature: String, devicePublicSPKIDER: Data) throws
HostAttach()
HostChallenge(coreGeneration: String, nonce: String, origin: String) throws
decodeHostChallenge(Data) throws -> HostChallenge
ActiveChallenge(requestId: String, coreGeneration: String, nonce: String,
                origin: String, deviceFingerprint: String, ownerPrincipal: String,
                requestDigest: String, deadlineMilliseconds: Int64,
                receivedAtMilliseconds: Int64) throws
decodeActiveChallenge(Data, receivedAtMilliseconds: Int64) throws -> ActiveChallenge
activeRequestBytes(coreGeneration: String, requestId: String, nonce: String,
                   deviceFingerprint: String, ownerPrincipal: String,
                   origin: String, deadlineMilliseconds: Int64) throws -> Data
hexDigest(Data) -> String
ActiveResultPayload(challenge: ActiveChallenge, host: HostProfile, reason: ActiveReason, checkedAtMilliseconds: Int64,
                    expiresAtMilliseconds: Int64, nowMilliseconds: Int64) throws
verifyHostIdentity(Envelope, challenge: HostChallenge, host: HostProfile) throws
verifyActiveResult(Envelope, challenge: ActiveChallenge, host: HostProfile,
                   nowMilliseconds: Int64) throws -> ActiveResultPayload
```

Host 서명 API는 package 접근의 `MobileEnrollmentSigner.receipt(_:identity:)`, `hostIdentity(_:host:identity:)`, `activeResult(_:challenge:host:identity:nowMilliseconds:)` 세 개다.

receipt의 `issuedAt`은 `floor(nowMilliseconds / 1000)`이다. `expiresAt`은 challenge 만료를 초로 내린 값, node 만료 초, issuedAt+10초의 최소값이다. challenge는 실제 nowMilliseconds와 비교해 남은 30초와 확정 clock skew 1000ms의 합 이내로 제한한다. `.500`·`.999`초의 분수를 초로 내리기 전에 잃지 않는다.

active의 deadline·checkedAt·expiresAt은 epoch 밀리초다. deadline은 수신시각보다 뒤이며 1500ms 이내다. 관측은 수신시각 이후, deadline 전이며 현재보다 최대 1000ms까지 앞설 수 있다. expiresAt은 checkedAt보다 뒤이며 2000ms 이내다. deadline과 expiry의 정확한 경계는 만료로 처리한다. 정수는 음수가 아닌 Int64와 JS safe integer 두 조건을 검사한다.

호출자는 다음 실제 경계를 공급해야 한다.

- 정본 Host의 실제 fd와 PeerAnchor 검증, 그 연결의 host challenge 증명에서 얻은 최초 full pin. HTTP SPKI 자체만으로 신뢰를 만들지 않는다.
- 실제 owner TLS의 기기 pin, 현재 ownerPrincipal, 발급 직전 Tailnet 2초 proof, 소켓 10초 admission, node 만료, active 등록·paired readback.
- actual registry 관측의 active/reason/checkedAt. 순수 signer는 registry나 Tailnet을 조회하지 않는다.
- 현재 socket/coreGeneration과 요청 nonce의 1회성, 중복 attach 거부, close·세대 변경·late response의 취소. 이 타입은 상태 캐시와 소켓 수명주기를 소유하지 않는다.
- receipt-only 응답의 필수 필드와 recognitionKey/proof 금지. 크기 검사는 순수 sizing fixture이며 실제 PairResult 배선 수용이 아니다.

세 전용 purpose는 각각 `ccr-mobile-enrollment-v1`, `ccr-enrollment-host-identity-v1`, `ccr-enrollment-active-result-v1`이다. private signer만 sortedKeys와 withoutEscapingSlashes JSON을 한 번 만든다. 모든 검증과 device proof는 전달된 payload·signature DER·SPKI DER 원문을 사용한다.

UUID는 검증된 소문자 문자열로 인코딩한다. active digest 원문은 `JSON.stringify([1,coreGeneration,requestId,nonce,deviceFingerprint,ownerPrincipal,origin,deadline])`와 같은 compact UTF-8이다. digest는 SHA-256 lower64hex다.

v1 공통 fixture의 암호 바이트는 그대로 보존한다. 잘못된 UUID MacID와 비hex principal은 생산 타입에서 거부한다. v2는 동일 raw crypto와 의미 검증을 함께 통과해야 한다. fixture 시각은 검사에만 명시 주입한다.

Core가 최종 확정한 ActiveReason 코드는 active·revoked·notRegistered·identityChanged·disabled·unavailable이다. active Bool은 reason에서 도출하고 수신 시 모순을 거부한다. 순수 `gatewayFailure` 매핑은 unavailable에 `503 ENROLLMENT_PROVIDER_UNAVAILABLE`, revoked에 `403 DEVICE_REVOKED`, 나머지 거부에 `403 OWNER_TRUST_DENIED`를 반환한다. 실제 HTTP 응답과 registry 조회는 gateway 호출자 소유다. 원시 오류 문자열은 wire reason으로 받지 않는다.
