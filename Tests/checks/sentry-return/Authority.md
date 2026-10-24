# 부모 glue에 연결할 순수 authority 경계

SentryReturnAuthority는 MainActor에서 동기 상태 전이만 수행한다. 네트워크, LA, 키체인, HAL, 서비스, 화면, 기기 효과는 없다. 이 타입과 DTO를 제품의 기존 host 안에 연결하는 작업은 부모가 소유한다. 새로운 listener나 장기 서비스를 만들지 않는다.

## 현재 연결과 명령

부모는 current closure에서 실제 연결 상태, 현재 페어링·owner 인가, host/TLS fingerprint와 pairing generation을 다시 확인한 Owner 및 현재 Sentry lease의 Snapshot을 제공한다. Owner의 생성 인자를 wire의 기기 주장으로 채우지 않는다. deviceFingerprint는 실제 TLS peer fingerprint와 같아야 한다. 동일 snapshot을 두 번 확인하며 closure 안에서 취소가 재진입해도 이전 작업을 승격하지 않는다.

handle은 응답 state와 typed commands를 반환한다. authenticateMac(ticket)은 그 요청에 연결된 공식 LA를 시작하라는 의도다. 부모 LA callback만 completeMacAuthentication(ticket,result,now,current)를 호출한다. result enum은 wire가 아니며 UI accepted bool·213 false를 이 완료로 변환하지 않는다. cancelMac(ticket)은 동일 시도의 LAContext와 대기 task만 취소한다.

deviceBoundKey의 prove는 authority가 직접 등록된 SPKI P-256 키와 challenge의 정확한 signingPayload를 CryptoKit으로 검증한다. 기기 callback이 인증에 성공했다는 bool은 받지 않는다. 이 서명은 등록된 키 소유를 증명한다. 기기 userPresence ACL의 하드웨어 attestation을 증명하지 않는다. 실제 기기 담당은 공식 인증과 키 연산 결합을 별도 검증한다.

## 복귀와 세션 reset

returnLocal(ticket)은 인증 뒤 복귀 준비를 시작하라는 의도다. 기존 participant·membership·오디오·입력 fence·readback 절차를 생략하지 않는다. 비동기 준비 중 기존 current/admission closure에 returnIsCurrent(ticket,now,current)를 결합한다. 준비 실패는 restorationFailed로 기록한다.

실제 host의 최종 동기 commit 바로 전에 authorizeCommit(ticket,now,current)를 한 번 호출한다. 이 API는 일회성 CommitPermit만 발급하며 Sentry admission을 변경하지 않는다. permit을 발급한 뒤 await로 다른 작업에 제어를 넘기지 않는다. 기존 completeLocalReturn이 세션·grants를 reset해도 이후 completeReturn(permit,result,now,currentOwner)은 독립적으로 검증한 현재 Owner를 받아 과거 완료를 기록할 수 있다. verifiedRestored는 실제 안전 복귀 readback 이후에만 전달한다. 준비 중에는 snapshot 전체, 정상 reset 이후에는 같은 owner/device/host/pairing identity를 확인한다. 취소·만료·분리 이후의 늦은 permit 완료는 거절한다. commit이 시작된 뒤 효과가 불명확하면 unknown을 기록한다.

completed는 해당 작업의 과거 결과다. 현재 화면 보호·동일 clientRunID 재접속 유지·새 run/명시적 ON 정책을 수용했다는 뜻이 아니다. wire의 currentProtection=notObserved 및 nextPolicy=parentAdmissionRequired를 유지하고, 부모가 현재 catalog/protection과 admission 정책 관측을 별도 연결한다. 본 변경은 externalRoute 재등록 재잠금 경합을 해결하지 않는다.

## 키와 원장

enroll/rotate/revoke는 모두 macLocal 요청과 현재 snapshot에 결속된 Mac LA ticket 완료가 필요하다. 첫 키는 기존 등록이 없을 때만, 회전과 해제는 현재 keyID가 일치할 때만 반영한다. keyChanged에는 이전/현재 공개키와 owner binding 및 승인한 Mac ticket이 담긴다. TLS 연결만으로 키를 등록하거나 새 앱 identity에 기존 키를 넘기는 API는 없다.

등록과 결과 원장은 이 순수 authority 인스턴스의 메모리에만 존재한다. 별도 키체인/디스크 저장이나 재시작 import를 구현하지 않았다. 부모가 키 저장을 추가할 때는 승인·binding·원장 readback을 유지해야 하며 TLS로 자동 재등록하면 안 된다. 권한 세대 변경은 활성 인증/복귀를 무효화한다. 새 authority는 이전 요청에 unknown을 반환하고 이전 boot의 request를 실행하지 않는다.

current는 기존 결과만 읽으며 인증·복귀·등록·만료 연장을 재실행하지 않는다. 정상 세션 reset 뒤 같은 Owner는 결과를 읽고, 다른 owner/device/host/pairing은 기존 결과를 받지 않는다. 기존 disconnect/revocation callback에서 disconnected를, 기존 이벤트 경로에서 expire를 호출하고 반환된 취소 의도를 실행한다. 별도 주기 서비스는 필요하지 않다. API의 시간 인자는 신뢰하는 host monotonic clock이며 wire 시간이 아니다. 원장은256개 상한에서 fail-closed하며 기존 요청을 제거해 재실행 여지를 만들지 않는다.

## 처리량과 검수

시작 게이트는 기준 a0b8e17과 별도 소유 워크트리 확인이다. DTO freeze와 실제 fixture hash를 먼저 부모에 전달해 Android/iPad/Vision의 독립 소비 구현을 열었다. 공유 가변 상태는 이 MainActor 인스턴스에 한정하며 실제 LA·공유 host 조작은 부모의 짧은 조율 구간이다. DTO와 authority의 암호학적 binding이 한 작업이므로 이 워크트리에서는 단일 작성자가 구현한다. 부모의 별도 워크트리 구현·기기 소비와 병렬 진행한다.

Pstack Feature/TDD와 Ponytail을 적용했다. ARENA 경로는 사용자 지시로 실행하지 않았다. 기준 생산 wire의223/224 부재를 실행해 실패시킨 뒤 구현했다. 전체 생산 StreamProtocol과 새 authority를 Mini에서 직접 컴파일하고 golden 및 순수 수명 검사를 실행한다. 독립 검수, host glue, 실제 인증·복귀·admission 수용과 정본 통합은 부모에게 남는다. 이 변경은 PR/운영 배포 권한으로 확대하지 않는다.
