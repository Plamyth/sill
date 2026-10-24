# 모바일 자동등록 순수 계약 writer

- [x] `how` over the affected subsystem. 기존 ProviderCallSigner와 HostIdentity.signRecord의 원문 바이트 계약을 재사용한다.
- [x] `architect` for parallel design exploration. skip: 사용자 ARENA·후속 에이전트 금지. 지정 typed 계약을 직접 스케치했다.
- [x] Blocking first steps. 기준 HEAD/tree, clean WT, 저장 정책, 계약 문서를 확인했다.
- [x] Independent workstreams. 부모 Host213 원격입력 수정은 별도 WT에서 계속한다.
- [x] Shared mutable state. 신규 소스 두 개와 신규 검사, 자기 audit만 쓴다.
- [x] Smallest safe decomposition. 이미 위임받은 단일 writer가 pure 계약과 signer를 함께 구현한다.
- [x] Delegate code-writing to a subagent. 사용자 지시로 후속 생성 금지. writer 직접 구현, 독립 reviewer는 부모 소유다.
- [x] Verify on the matching surface. 초기 소스 부재 red, 500ms 반례 invalidTime red, 수정 후 순수 계약 129개와 Node JSON.stringify 교차 검증을 통과했다. macOS/iOS/visionOS SDK의 전체 StreamProtocol typecheck를 통과했다. 최대 receipt-only JSON은 1070바이트, 기존 14바이트 header를 포함한 frame은 1084바이트이며 4096바이트까지 3012바이트 남는다. 검사 전후 입력과 맥북 정본의 SHA를 대조했다.
- [x] Rebase into small, ordered commits. 정확 기준에서 이 writer의 신규 파일만 하나의 작업 커밋으로 반환한다.
- [x] If the design is contested, `interrogate` before shipping. skip: 확정 계약, 논쟁 없음.
- [x] Run Opening a PR. skip: push/PR/통합/설치는 부모 소유.
- [ ] BLOCKED: independent review. 별도 reviewer 소유이며 writer는 대리 수용하지 않는다.

스케치 전달 시도는 send_message_to_thread가 native ancestor 전송을 거부했다. native collaboration 도구는 노출되지 않았고 Reason 목록은 thread ID 매핑을 제공하지 않아 다른 세션에 임의 전달하지 않는다. 이 audit와 진행 보고에 스케치를 남긴다.

최초 API 스케치는 Core 추가 확정 후 `mobile-enrollment-api-20261025.md`로 갱신했다. InitialChallenge.schema는 후속 확정된 `ccr.device-challenge/v1`이며 HTTP parser는 만들지 않는다. ReceiptInput은 실제 nowMilliseconds를 받아 issuedAtSeconds를 내림 계산한다. HostIdentity와 typed input만 받는 세 전용 signer는 실제 등록 인가·Tailnet proof·TLS admission을 판정하지 않는다.

Model the Domain 원칙으로 pin·기기키·principal·시각·목적별 데이터를 immutable typed model에 모았다. Sequence work into verifiable units 원칙으로 red 반례와 green 영수증을 구분한다. Ponytail은 기존 Base64URL, SPKI, MacID, JSONEncoder, Apple Security와 CryptoKit을 재사용했으며 새 의존성·키 저장소를 추가하지 않았다. private flat scalar decoder만 신규 wire 경계에 한정했다.

독립 검수는 다른 reviewer가 맡는다는 사용자 지시를 유지한다. `architect`의 ARENA와 추가 에이전트 생성은 사용자 금지로 실행하지 않았다. `no-comments`의 별도 reviewer 생성도 같은 이유로 생략하며 독립 검수 완료로 표시하지 않는다. 일반 signer API, runtime 인가, 소켓 배선, HTTP 처리, 계정·token·서비스·Host 실행, TLS enroll, UI·HAL 조작은 수행하지 않았다.

Core가 active/revoked/notRegistered/identityChanged/disabled/unavailable을 최종 확정했다. true는 active에서만 도출하고 wire의 모순·미지원 reason을 거부한다. 순수 gatewayFailure 매핑도 확정 코드와 대조했다. v2 공통 fixture는 SHA 12c3fdf84163ed9407f5b82bb10c96baa3fda387b93870f5fe49023d3bdef059의 원문으로 crypto·semantic을 통과한다. v1 e921245c43378dbd66620d60583e176dd8f786fbb50ea17f70e00d11bbec38b9은 crypto만 통과하고 semantic에서 적법하게 거부한다.
