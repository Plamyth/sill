# 구현 전 계약 스케치

기준 bf89ec30ceb693d01d71b604a889254342fb5577. 부모는 긴급 TCC/Host213/Core pin과 실제 통합을 소유한다.

`@MainActor package func RemoteAccess.mobileEnrollmentObservation(challenge: MobileEnrollment.ActiveChallenge, nowMS: Int64) throws -> MobileEnrollment.ActiveResultPayload`

`OwnerBootstrapRegistry.observation(principal: String, fingerprint: String, paired: [PairedDevice]) -> MobileEnrollment.ActiveReason`는 internal current-read pattern이다. exact active registry binding과 유일 paired 지문을 함께 요구한다. `ownerPrincipal=nil` explicit qr/code/icloud/cable도 기존 bootstrap이 해당 기록을 보존하므로 active exact binding과 함께 있을 때 지원한다. pending은 거부한다.

receipt는 실제 owner socket과 2초 Tailnet proof 검증 직후, 기존 registry 저장 이전에 분기한다. 동일 연결에서 전용 1회 소비를 서명 전에 확정한다. 결과 불명확도 재발급하지 않는다. 서명 전/후 store registry+paired readback, socket admission, epoch, remoteAccess, 취소와 proof current를 동일 결정 안에서 대조한다. 긴 await 추가는 없다.

Door raw strict scanner는 owner ALPN에만 적용한다. 중첩 unknown/null/type은 StreamProtocol custom Decodable에서 거부한다. 일반 pairing·일반 owner recognition 동작은 유지한다. typed signer를 복제하지 않는다.

직접 부모 메시지 도구가 조상 전송을 거부했고 Reason도 실제 세션을 찾지 못해 이 스케치를 공유 가능한 감사 파일과 진행 문장에 먼저 남겼다. 독립 검수·runtime composition·push/PR/통합·설치는 부모 소유다.

## 최종 배선 계약

조회 API는 위 스케치 그대로다. runtime writer의 `@MainActor @Sendable (MobileEnrollment.ActiveChallenge) throws -> Observation`에서 부모가 반환 payload의 `reason`과 `checkedAt`을 `Observation(reason:checkedAtMilliseconds:)`에 연결하면 된다. 이 writer는 runtime 객체를 생성하거나 새 runtime 파일을 수정하지 않았다. 공개 Host profile export를 추가하지 않았으며 과거 profile을 fresh pin으로 승격하지 않았다.

`OwnerEnrollmentRequest(challenge:devicePublicKey:)`와 `PairRequest(..., ownerEnrollment:)`가 새 입력이다. 기존 kind 19 v2·owner-tailnet-v1·proof empty·cable 없음과 owner ALPN은 유지한다. Host receipt-only 성공은 ok/method/macID/ownerEnrollmentVersion/ownerReceipt의 정확 5필드이며 recognitionKey/proof/name은 없다. 기존 bootstrap에는 여전히 recognitionKey가 반환된다.

저장소 확인은 현재 signed registry·paired를 각각 두 번 읽어 일관성을 확인한다. 이 읽기와 서명은 기존 재진입 TrustBox 결정 안에서 수행하지만 소켓 NSLock·센서 NSLock을 잡은 채 I/O를 하지 않는다. 소켓 1회 소비만 짧게 잠근 뒤 풀고, 실제 binding·10초 admission·2초 sensor proof를 서명 직전과 저장소 재검사 뒤 반환 직전에 다시 대조한다. 재진입 socket.cancel·sensor.stop·설정 변경·원장 철회를 검사한다. 이 구간에는 await가 없다. 생산 keychain I/O 지연이 proof TTL을 넘으면 거부하며 실제 지연 측정은 이번 소스 검사의 수용 범위가 아니다.

`currentEnrollmentReason`은 cache ownerRegistry를 인가에 쓰지 않는다. registry active exact principal/fingerprint와 현재 paired의 유일 동일 지문·pending 아님을 요구한다. owner method는 principal까지 일치해야 한다. qr/code/icloud/cable의 principal=nil은 signed active exact binding과 함께 있는 경우만 지원한다. pending/revoked/missing/identity collision/store 오류는 receipt를 발급하지 않으며 저장·재활성화·trust authorize를 하지 않는다.

nodeExpiry는 seconds floor이며 `maximumSafeInteger/1000`으로 상한 처리한 뒤 Int64로 변환한다. Date.distantFuture도 이 경로를 거친다. signedInput의 exact issued milliseconds와 expiry를 보존해 서명 후 재조회 중 시계 후퇴·만료를 거부한다. 실제 TTL은 기존 ReceiptInput의 min(challenge expiry floor,node expiry floor,issued floor+10)이다.

nonce는 Host가 생성하거나 갱신하지 않는다. 연결별 receipt 시도는 서명 실패·결과 불명확도 한 번으로 소모하며 같은 연결의 같은 nonce/새 nonce 재시도를 모두 거부한다. 새 TLS 연결의 유효 현재 claim을 gateway의 전역 nonce 최종 single-use 소비로 오인하지 않는다. 클라이언트의 자동 bootstrap→새 연결 receipt-only 소비와 실제 HTTP 등록은 이 Host 소스 작업 밖이며 설치/실물 수용은 없다.

독립 비작성 검수는 부모 소유로 아직 미수용이다. 이 writer의 자체 검사·빌드를 독립 검수나 실제 배선 수용으로 표시하지 않는다.

## 검증과 한계

최초 missing API RED와 최종 소켓 재조회 중 Task 취소 RED를 각각 재현했다. 최종 생산 코드 기반 receipt 검사 116개와 기존 owner 호스트 검사 1077개가 통과했다. 서명 직후 store 재조회 중 철회, epoch 변경, socket.cancel 재진입, remoteAccess 변경, sensor.stop 재진입, challenge floor 만료와 최종 socket 검사 중 Task 취소를 포함한다. 4096/4097 byte 경계와 unknown/duplicate/escaped duplicate/null/type 거부를 검사한다.

StreamProtocol 전체를 macOS arm64 14.0, iOS arm64 17.0, visionOS arm64 2.5 SDK로 검사했다. 기본 xcode-select의 CLT 경로는 바꾸지 않았다. 모바일 SDK 조회·생산 메뉴바 앱 빌드 프로세스에만 기존 `/Applications/Xcode.app/Contents/Developer`를 지정했다. CLT의 SwiftUI 매크로 누락 실패는 별도 로그로 보존하고 Xcode 생산 Release 빌드 통과로 해소했다.

검증된 소스 해시는 외장 `verification.json`의 before/after 및 `production-release-xcode.json`의 source와 다시 대조했다. 실행파일을 빌드만 했으며 실행/설치/실제 keychain/TLS/network/Host/service/UI/audio 변경은 없다. 테스트 키는 MemoryIdentityStore의 메모리 전용이다. Host runtime observer를 실제 연결하지 않았다.

Pstack Feature의 데이터 모양 우선 원칙을 OwnerEnrollmentRequest와 ActiveReason에 적용했다. Ponytail은 기존 OwnerBootstrapSocket, TailnetDeviceAccess, signed registry, strict JSON scanner, typed signer 재사용을 선택하는 데 적용했다. 새로운 서버·listener·범용 signer·키 저장소·runtime 객체를 추가하지 않았다. 독립 비작성 검수와 실제 통합·설치·소비자 자동 요청 수용은 부모 소유로 남았다.
