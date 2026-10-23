# Provider 호출 승인 경계 검사

기준 Sill `67603596bbebe3e2b3aaf970859935fd5bfc732f` / tree
`0bf2a6f9c116a8894728bb8a57d8066ecabba590`, Node
`0bec7a9970b0bd4e15390012b8ade02ed54605c2`를 검사한다.

```sh
python3 Tests/checks/provider-call-admission/run.py NODE_CHECKOUT EXISTING_OUTPUT_DIRECTORY
```

새 패키지나 XCTest 없이 기존 Swift 컴파일러, CryptoKit/Security, Node만 사용한다.
Node checkout에서는 위 커밋의 Git blob을 읽는다. Git 없는 Mini 입력에서는 서버
19개 전체를 생산 `LocalAudioRelayClosure.swift`의 SHA-256과 대조한다.

## 실제 실행 범위

- 생산 `LocalAudioRelay.swift`와 `ProviderCallBridge.swift`를 그대로 컴파일한다.
  `providerAcquire`, `providerDispatch`, `providerRelease`, `providerCancel`,
  Prepared/Approval와 실제 signer가 검사 대상이다.
- 기존 `forwarding-evidence-lifecycle`의 `child.js`, `Boundaries.swift`와
  `Main.swift`의 `@main` 이전 Fixture/Peer를 재사용한다. 새 정책 판정기나
  가짜 provider authority를 만들지 않는다. 이 재사용이 기존 42개 전체 재실행을
  뜻하지는 않는다.
- 실제 Node authority/native control/audio session의 private stdio를 사용한다.
  `/arm`은 Node가 실제 응답을 만든 뒤 전송만 늦추며 `/release`가 이를 해제한다.
- 생산 runtime 사본에는 테스트 관측 함수와 polling 중지 함수만 덧붙인다.
  polling은 실제 native binding 준비 후 중지해 await 경계에 다른 RPC가 끼지 않게
  한다. 오디오 준비·보호·worker는 기존 inert fixture다.
- `HostIdentity.swift`의 `signRecord`/`verifyRecord`를 원문 그대로 선택 컴파일한다.
  초기화만 공개된 고정 테스트 스칼라의 메모리 키와 생산 RemoteIdentity로 대체한다.
  실제 Mac 키, IdentityStore와 Keychain 로딩 코드는 컴파일하거나 호출하지 않는다.
  서명 결과는 별도 CryptoKit 공개키 검증과 실제 payload 필드로 판정한다.
- raw scope 서명 API, Prepared/Approval 직접 생성, request/challenge 덮어쓰기는
  별도 선택 컴파일의 구체적인 접근·불변성 오류로 거절됨을 확인한다.

## 결과와 정리

각 동작 검사와 실패를 수집해 끝까지 실행한다. `ADMISSION_RESULT=` JSON에
실패 목록, fixture stdio 로그, 정확한 자식 PID·임시 포트·종료 확인,
원본/선택 소스 SHA와 Node 핀을 남긴다. 제품 결함은
검사를 성공으로 바꾸지 않으며 종료 코드 1로 반환한다.

자식 Node HTTP는 `127.0.0.1:0`, journal/테스트 credential은 전용 임시 디렉터리다.
실제 17648/17649, 실제 provider/원장/UI/앱/기기/HAL/권한을 사용하지 않는다.
정상 종료는 Fixture가 보유한 Process만 닫는다. 오류 시 runner가 자신이 생성한
프로세스 그룹만 종료하고 임시 디렉터리를 제거한다. credential/키 파일은 결과에
복사하지 않는다.

Mini 실행은 task 전용 snapshot과 `mini-ephemeral-source` 정리 영수증으로
기록한다. 부모의 source-guard 캡처와 exact base 대조는 별도다. Git 없는 Mini
snapshot을 source-guard의 checkout 기반 동일 작업 수용으로 주장하지 않는다.

## 기준 소스에서 관측한 실패

`release-before-proof`는 실제 Node의 `recorded` Release 응답 뒤에도 아직 사용하지
않은 Approval이 현재 상태로 남고 실제 signer가 서명하는 P2를 재현한다.
생산 `LocalAudioRelay.swift:576`의 Release는 Prepared의 로컬 철회를 수행하지 않는다.

`foreign-cancel`은 다른 relay를 receiver로 호출해도 `LocalAudioRelay.swift:567`이
소유권 검사보다 먼저 원 Prepared를 철회하는 경계를 드러낸다. 이 검사의 기대는
잘못된 receiver가 다른 actor의 승인을 철회하지 않는 것이다. Node 권한 확대나
실제 클릭 증거가 아니며, 부모가 의도한 cancel 계약과 별도로 대조할 항목이다.
같은 actor의 이전 Cancel이 새 scope를 보존하는 검사는 통과한다.
