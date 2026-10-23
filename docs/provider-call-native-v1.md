# 원격 통화 명령 v1

공통 Sill 호스트가 StreamProtocol 번호를 소유한다. 기준은 공식 호스트 `215d8e451ef53c9d91e2b989cb5ac2d9827eb1e3`, Node authority `0bec7a9970b0bd4e15390012b8ade02ed54605c2`다. 이 문서와 DTO가 있어도 설치본이나 실제 통화가 지원된 것으로 판정하지 않는다.

## native 계약

- 221 `providerCallControl`은 paired TLS viewer에서 호스트로만 보낸다. payload 상한4096바이트다.
- 222 `providerCallState`는 호스트에서 같은 연결로만 보낸다. payload 상한16384바이트다.
- 219/220은 기존 reserved를 유지한다.217/218의 엄격한 음성 intent/관측 DTO는 바꾸지 않는다.
- 현재 연결의 WindowList `providerCalls:1`을 받은 기기만221를 보낸다. absent/다른 값/다른 연결의 이전 값이면 보내지 않는다. 구기기는 optional 필드를 무시하고 기존 기능을 쓴다.
- 이 capability는 호스트가 계약을 파싱한다는 뜻이다. 실제 Core·DOM·인증·미디어 준비 또는 실제 통화 성공을 뜻하지 않는다.

요청의 정확한 키는 다음과 같다.

```json
{"schemaVersion":1,"operation":"perform","request":{"requestId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","action":"start","expectedLeaseRevision":"7","pairedDeviceId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","desiredInput":true,"desiredOutput":true,"callSessionId":null}}
```

operation은 perform/query다. query도 원래7필드 request를 그대로 보낸다. query는 결과 조회이며 Acquire/Dispatch/새 클릭을 실행하지 않는다. unknown에 새 requestId를 발급하거나 앱 복귀·재연결·입출력 선택을 통화 시작으로 바꾸지 않는다.

requestId는 UUID, action은 start/stop, expectedLeaseRevision은 UInt64 정규 십진 문자열, pairedDeviceId는 SPKI SHA256 소문자 hex64다. 방향은 boolean이다. callSessionId는 null 또는1..128 UTF16 code unit의 문자열이며 start는 null이어야 한다. 빈 문자열과 단독 surrogate는 거부하고 Unicode 정규화를 하지 않는다.

응답의 정확한 키는 schemaVersion/requestDigest/result다. result의 키는 requestId/status/reason/callSessionId/provider/mediaProtection다. status는 started/stopped/unsupported/failed/unknown/pending이다. provider는 chatgpt-dots-webguest, mediaProtection은 not_attested다. reason은 내부 오류 코드이며 사용자 화면은 한국어로 표시한다. 미디어 보호 증거는 기존 별도 음성 계약에서 확인한다.

started/stopped는 실제 공식 UI의 phase/session readback을 Host가 현재 paired admission과 새 Node snapshot에 대조한 결과만 쓴다. Node Dispatch 승인, Core activated, 서명 생성, 메시지 전달은 통화 성공 ACK가 아니다.

## 동시성과 재접속

같은 TLS에217/218 슬롯1개와221/222 슬롯1개를 독립 관리한다. 통화 UI 결과 대기 중에도217의1Hz 관측·송신 시각+3초 freshness를 유지한다. provider 슬롯으로 기존 관측을 drain하거나 유효기간을 연장하지 않는다. Node private pipe는 기존 직렬 RPC이며1500ms scope에는 버튼 전달 구간만 둔다.

호스트는217.observe로 등록된 현재 TLS의 실제 paired session을 재사용한다. request의 기기/revision/desired를 같은 Node actor에 대조하며 credential은 private pipe에만 둔다. 다른 actor나 세대의 결과는 반환하지 않는다. 같은 requestId의 다른 requestDigest는 conflict다. 같은 요청은 현재 결과만 반환하고 다시 클릭하지 않는다. 프로세스 재시작 뒤 기존 Node journal의 providerActions가 재승인을 막는다. cache가 없는 query는 unknown이며 새 실행이 아니다.

221 미응답의 기한은 최초 송신부터10초다. 미완료 슬롯이 있는 동안 새221를 보내지 않으며, 기한이 지나면 해당TLS를 폐기한다. 새TLS에서도 원 requestId와 digest를 유지한 query만 허용하며 자동 perform은 하지 않는다. pending 조회는 원 perform 최초 송신부터 총10초 이내, 간격 최소500ms, 최대4회다. 예산을 다 쓰면 unknown을 유지하고 새 effect를 만들지 않는다. Host도 pending query 예산을 확인하지만 기기 최초 송신 예산을 늘리는 근거로 쓰지 않는다.

본문과 연결·세대·requestDigest가 맞지 않는 늦은222는 새 요청이나 새 권한으로 쓰지 않는다. provider 오류·기한초과가 다른 TLS/기기의217, 화면, 입력, 음성 소유권을 바꾸면 안 된다.

## Core UDS 교환

기존 CommandGateway listener를 쓰며 새 listener/HTTP/key/token/페어링을 만들지 않는다. UDS를 여는 실제 sender는 서명된 Sill 본체다. Host도 동일 소켓 상대의 audit token, md.obsidian/6JSW4SJWN9 서명, canonical /Applications/Obsidian.app 설치 경로와 live/disk CDHash 일치를 교환 전후에 확인한다. Node 자식이나 helper의 OS peer를 부모 PID 주장으로 대신하지 않는다.

1. `{op:'provider.challenge',schemaVersion:1,request}`를 보낸다. Core는 같은 net.Socket의 복제fd를 native verifier로 넘겨 audit token의 dynamic code와 정확한 canonical 설치본을 확인한다.
2. challenge는 schemaVersion/challenge/coreGeneration/requestId/target/targetHash/guestNowMs/remainingMilliseconds의8필드다. challenge는32바이트 canonical Base64URL, 세대와 requestId는 UUID, remaining은1..1500ms다.
3. `{op:'provider.identity',schemaVersion:1,envelope}`로 identity 서명 envelope를 보낸다. envelope는 payload/signature/publicSPKI의3필드다. identity body는 schemaVersion/purpose/challenge/coreGeneration/requestId/requestDigest/macFingerprint의7필드다. Core는 검증된 같은 peer의 공개 identity만 연결에 고정하며 다른 키를 자동 채택하지 않는다.
4. identity ACK는 schemaVersion/requestId/coreGeneration/challenge/requestDigest/targetHash/state의7필드이며 state는 identity_verified다.
5. `{op:'provider.dispatch',schemaVersion:1,envelope}`를 보낸다. Host는 실제 private Acquire/Dispatch를 거친 불변 승인에서만 dispatch body를 만든다. body는 schemaVersion/purpose/request/requestDigest/challenge/coreGeneration/targetHash/pairedDeviceId/pairingGeneration/authorizationGeneration/scopeId/nodeGeneration/intentGeneration/bindingEpoch/macFingerprint/remainingMilliseconds의16필드다. pairing/authorization은 현재 같더라도 각각 서명한다.
6. 전달 ACK는 identity ACK의6개 식별 필드에 state/reason을 더한8필드다. state는 activated/not_dispatched/unknown이며 즉시 반환한다.
7. Host가 private Release를 수행한 뒤 읽기 전용 `{op:'provider.result',schemaVersion,requestId,coreGeneration,challenge,requestDigest,targetHash}`로 결과를 조회한다. 응답은 op없는6개 식별 필드와 기존6필드 result다. UI 연결 대기를 Node scope에 넣지 않는다.

identity/dispatch의 서명 메시지는 목적 문자열 UTF8 + NUL + 받은 payload 원문 bytes다. 목적은 각각 ccr-provider-identity-v1 / ccr-provider-dispatch-v1이며 body.purpose도 일치해야 한다. payload/SPKI/signature는 canonical unpadded Base64URL, SPKI는 기존 Mac P-256 DER91바이트, fingerprint는 DER SHA256 hex64, 서명은 ECDSA X9.62 DER다. Core는 받은 bytes에 서명을 검증하고 JSON을 strict 검사하며 재직렬화한 bytes가 같다고 추정하지 않는다.

현재 Actor의 request/target/challenge/coreGeneration과 보수적 기한은 실제 Acquire 전에 고정한다. raw scope나 호출자가 바꾼 request/target으로 일반 signRecord를 호출하는 endpoint는 없다. Dispatch 승인 뒤 취소·기한·문서·Node 세대 변화나 결과 불명은 unknown이며 자동 재클릭하지 않는다. 외부 guest 클릭과 Node 철회의 원자성을 주장하지 않는다.

## digest와 시계

requestDigest는 Node journal 내부 requestHash와 다르다. UTF8 ccr-provider-request-v1 + NUL 뒤 requestId의 lowercase UUID/action/정규 십진 revision/lowercase pairedDeviceId를 UInt32 BE 길이+UTF8으로 붙인다. 방향은 각0/1바이트, session은 null이면0, 문자열이면1+길이+UTF8이다. 원본 고정 벡터는 Tests/checks/provider-call-bridge/vectors.json이다.

Target은 profileId/leafId/guestId/url/timeOrigin의5필드다. targetHash는 Node 문서의 ccr-provider-target-v1 JSON 배열과 timeOrigin binary64BE 인코딩을 그대로 사용한다. exact href를 origin/path로 줄이거나 허용되지 않은 query/hash를 해시해 승인하지 않는다.

Host는 challenge 송신 h0+challenge.remaining과 Node Acquire 송신 n0+Node.remaining의 min을 취하고 이후 기한을 늘리지 않는다. 서명 remaining은 그 기한−현재 Host monotonic의 내림이다. Core는 자기 c0 기준 min(원 challenge만료,c0+signedRemaining,전체 operation만료)를 최초 guest inspect의g0/수신hInspect로 환산한다. 수신시각에 remaining을 더하거나 서로 다른 clock epoch를 빼지 않는다. guest 마지막 만료 검사와 click 사이에는 await/타이머가 없다.

## 수용 경계

실제 활성화 전에 providerActions를 읽는 동일 reader의 정확한 서명 복구 후보가 필요하다. Host는 ~/Library/Application Support/CCR Sill/Recovery/CCR Sill.app의 기존 designated requirement, canonical 경로, 전체 자원 서명, 현 Node0bec reader의 매니페스트·19개 핀·의존성 파일을 실제로 대조한다. 이 검사는 복구 앱을 실행하거나 실제 복구 성공을 뜻하지 않는다. 구149/099 포인터 복귀나 journal 복원/삭제로 우회하지 않는다. source/SDK/서명 후보, 설치된 runtime, 실제 signed peer, 실제 UI 통화, M32R 포함 물리 입출력과 각 기기 수용은 각각 구분한다.
