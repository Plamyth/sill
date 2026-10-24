# iPad Sentry 인증 복귀 소비부

전용 기준은 `8f5f5b0e66d5b142779ec6e34112219de5b5c8f9` 및 tree `ca0343c8e77c3a577bd5c909bb2d6269007a0775`다. 공유 `SentryReturn.swift`, Authority, fixture는 변경하지 않는다. fixture SHA256은 `16a280f5d9f8623bc30eee88dd4fd3c143523d1c14bdb0e9a8869231c4282187`다.

## 상태와 전송

`IPadSentryReturn`은 요청 원문, digest/reference, TLS binding, 원래 lease와 raw challenge/state를 별도 원장에 보존한다. 새 요청과 current 조회는 다른 wire 동작이다. 현재 pinned binding과 유효한 광고를 읽기 문맥으로 두고 lease는 optional로 보존한다. 정상 reset으로 현재 lease가 없어도 명시 current는 원래 reference만 보낸다. 새 request/prove에는 fresh lease가 필요하다. 원장 저장 실패, 재시작, timeout, 취소는 새 ID나 등록을 자동 발행하지 않는다. 원장 상한은 64개이며 기존 요청을 지워 재실행 가능성을 만들지 않는다.

일반 복귀의 completed는 localReturned만 수용한다. 키 요청은 원래 action의 keyEnrolled/keyRotated/keyRevoked만 수용한다. 과거 완료와 현재 보호·오디오·입력 수용은 분리한다. 최초 challenge 없이 키 완료만 받으면 raw completion을 보존하고 결속 복구를 기다린다. 이 상태에서 기존 키를 승인하거나 새 등록을 발행하지 않는다.

`WindowList.sentryReturn` 원문 하위 객체만 엄격 decode한다. 필드 부재나 잘못된 capability는 다른 catalog 소비자를 실패시키지 않는다. 실제 Host 217·218의 광고와 glue는 아직 없으므로 실제 송신은 미지원이다. source/fixture 준비를 Host 실행 지원으로 표시하지 않는다.

송신은 실제 `SessionLink`의 `onlyOn`, `Submission`, 잠금 보호 불변 ticket을 사용한다. admit callback은 main 소유 배열·UI·consumer를 읽지 않고 main.sync도 호출하지 않는다. 연결 교체·취소·비활성·세대 변경은 보류된 송신과 인증 operation을 무효화한다. savedMacs·session·connected의 메인 observer는 revoked/newKey/pin·session binding 변경 시 같은 gate와 보류 Submission을 무효화한다. 명시적 기기 복귀 버튼의 메모리상 일회성 intent만 같은 요청의 challenge를 native 서명으로 이어 준다. current·catalog·재시작은 인증 UI를 시작하지 않는다.

## 전용 키

`IPadSentryReturnKeys`는 TLS DeviceIdentity·페어링키·마이크 grant와 다른 purpose의 P-256 키를 다룬다. 명시 enrollment에서만 키를 준비하고, 첫 등록의 owner/pairing은 같은 TLS의 challenge와 Mac LA 완료를 받은 뒤 로컬 키 UUID/SPKI에 결속한다. candidate·approved·retired·revoked를 분리하며 기존 기록·키를 삭제하지 않는다. 과거 완료를 재조회해도 폐기된 키를 다시 활성화하지 않는다.

CryptoKit 생성자에 `SecAccessControl`의 `.privateKeyUsage`, `.userPresence`와 `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`를 명시한다. 기본 ACL은 사용하지 않는다. 보호 opaque blob과 메타데이터는 별도 비동기화 Keychain 항목에 저장하고 단일 앱 프로세스 내 잠금, 비교 후 쓰기, readback을 적용한다. Keychain 자체의 다중 프로세스 트랜잭션을 보장한다는 뜻은 아니다.

서명은 받은 raw state의 표준 base64 원문에서 해제한 bytes만 사용한다. DTO 재인코딩은 tuple 동등성 확인에만 쓴다. SPKI DER 91바이트와 ECDSA DER을 사용하고, 이중 SHA256·point65·raw64는 수용하지 않는다. 별도 LA 성공 bool을 원격 인증 결과로 보내지 않는다. Simulator는 명확히 미지원이며 소프트웨어 fallback은 없다.

설치 SDK `iPhoneOS27.0.sdk`의 `CryptoKit.swiftmodule/arm64e-apple-ios.swiftinterface`에서 생성·복원·서명 선언을 확인했다. 인터페이스 SHA256은 `eb8c7224416628837d54179437b28792a6ca6a2b95dc3ba35d43ce7a92e19ce7`다. Apple의 [Secure Enclave 생성자](https://developer.apple.com/documentation/cryptokit/secureenclave/p256/signing/privatekey/init(compactrepresentable:accesscontrol:authenticationcontext:))와 [userPresence](https://developer.apple.com/documentation/security/secaccesscontrolcreateflags/userpresence)가 API 근거다. 실제 기기의 Secure Enclave·Face ID·장치 암호 수용 증거는 아니다.

## 검사 실행

`python3 Tests/checks/ipad-sentry-return/run.py 고유-label`은 기존 reconnect-glue Mini RAM helper를 재사용한다. 실제 protocol·consumer·키 adapter·SessionLink·StreamClient extension을 컴파일한다. Network는 기록 대역이며 native 키 연산은 알려진 golden fixture 키만 사용한다. 소스/입력 해시와 RAM·임시 출력 제거 영수증을 storage-route가 정한 외장 경로에 남긴다. codex-source-guard의 작업 이전 수용과는 별도인 좁은 검사다.

`python3 Tests/checks/ipad-sentry-return/sdk.py 고유-label`은 맥북에만 설치된 iOS SDK에서 실제 adapter/consumer를 typecheck하고 StreamClient/UI를 parse한다. 전체 iOS 앱의 link/build는 부모 범위다. 실키 생성·생체 UI·등록 송신·Host·음성·설치 조작은 실행하지 않는다.

## 부모가 수용할 경계

Host의 Owner-only current glue와 Snapshot=nil 회귀, 최초 challenge를 잃은 키 승인의 keyID/SPKI/owner/pairing 읽기 계약은 후속 정확 commit/fixture가 필요하다. 클라이언트는 이 자료를 추정하지 않는다.

Hello.clientRunID의 process 수명과 Host의 검증 owner/device/auth generation/run 집합은 별도 생산자 범위다. 이 소비부는 Hello 필드를 추가하거나 legacy nil에 재잠금 억제 예외를 주지 않는다. 정확 후속 commit·fixture·독립 검수 전에는 생산자 수용을 주장하지 않는다.

Pstack Feature에서 단일 소유 consumer·키 원장·UI를 구현했다. Model the Domain과 Boundary Discipline을 Entry/Owner/Proof 및 입출력 검증에 적용했다. Ponytail full은 기존 DTO·SessionLink·플랫폼 API 재사용에 적용했다. ARENA·순정 Goal·새 하위 에이전트는 실행하지 않았다. 독립 계약 검수, 최종 SDK·공식 integration·설치와 실물 수용은 부모가 소유한다.
