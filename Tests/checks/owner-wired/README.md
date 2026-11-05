# 등록 owner iPad USB 후보 검사

이 검사는 `DiscoveryPolicy`와 `OwnerWiredPolicy` 원문을 컴파일하고, 현재 `StreamClient.swift`의 owner 연결·취소·카탈로그 판단 메서드 및 `startMove` 상태 콜백을 그대로 추출해 결정적 I/O 대역으로 실행한다. 키체인·DNS·TLS·기기·Host·오디오는 실제로 조작하지 않는다. `finishMove`의 내부 fence 전송 및 암호학적 서명 검증 자체는 대역이며 실제 네트워크·실기 수용을 증명하지 않는다.

실행은 저장소 루트에서 `python3 Tests/checks/owner-wired/run.py`이다. 이 작업에서는 parent `01a13ace-e372-7ed1-9946-149df37ee1c3` 소유의 공식 `mini-ephemeral-source` 경로로 실행하고 소스 삭제 영수증을 확인했다.

검사 범위는 실제 IPv6/IPv4 바이트와 scope/인터페이스/자기 주소/동일 인터페이스의 글로벌 주소 거부, 기존 등록·pin·기기 키·저장 포트 검사, 초기 등록 경계 보존, Tailnet 복구 호출, 콜백 세대와 기존 peer 보존, 횟수 제한과 기존 backoff, TLS ready·카탈로그·서명 확인 단계 분리, 다른 Mac/launch/pin·늦은 콜백·Host 미지원·실패 후보·인터페이스 변경과 오디오 재바인딩 전 차단이다.

## 구현 선택과 역할

Pstack의 feature 경로를 사용하고, Ponytail full의 기존 구조 재사용 원칙으로 기존 move/probe/SessionLink와 remote session mTLS를 재사용한다. ARENA와 순정 Goal을 사용하지 않는다. 직접 위임받은 단일 writer가 이 독점 워크트리의 결합된 client 변경을 맡고, parent가 정확한 소스의 독립 검수·공식 XCTest·서명·설치·Core/Host 계약과 실제 음성 입출력을 맡는다.

- 선행 조건: 사용자 AGENTS·최신 결정·저장 정책과 기준 `ff98f3c05361ee9a6777704c80783e3c30413f04`, 독점 브랜치 및 처음 clean 상태를 확인했다.
- 독립 작업: parent의 XCTest/실기 준비와 Host 원담당, 별도 UI 워크트리는 이 writer와 파일·실행 자원을 공유하지 않는다. 이 작업의 pure 검사와 Mac 필수 SDK 컴파일은 병렬 실행했다.
- 공유 가변 상태: 실제 기기·Host·오디오·registry·서비스·브라우저는 조작하지 않는다. 이 client 후보는 저장된 정확한 pin과 기존 기기 키만 읽고 물리 경로를 재검증하도록 구현했다.
- 최소 분해: resolver/정책/StreamClient 접합은 한 writer가 소유한다. 추가 하위 writer는 만들지 않고 독립 검수를 parent에 남긴다.

## 통합 시 확인할 사항

Bonjour는 발견 전용이며 DNS-SD의 포트와 TXT를 신뢰하지 않는다. `DNSServiceResolve`와 IPv6 `DNSServiceGetAddrInfo`를 현재 유선 인터페이스로 제한하고, 실제 목적지는 저장 `remotePort`이다. 등록 owner의 USB는 legacy home 신뢰로 변환하지 않고 remote-door session으로 유지한다. 저장 주소와 `lastWorked`에 USB 주소를 승격하지 않는다.

Host 242의 물리 NCM·TLS fingerprint·현재 서명 registry active 기기/principal/epoch 재검증이 별도 선행 의존이다. 이 구현은 owner receipt를 해석하지 않는다. 후보가 거절되거나 첫 카탈로그 전에 실패하면 Tailnet로 복구하며, 정상 Tailnet 옆의 move 실패는 기존 세션을 유지한다. 같은 발견 세대의 USB 시도는 최대 두 번이며 대기에는 기존 `DiscoveryPolicy.upWait`를 사용한다.

최종 인계의 source hash·commit/tree·Mini 영수증·SDK 결과는 storage-route가 반환한 외장 산출물 경로에서 확인한다. 공개 owner 프로필 공급 없이 전체 앱 패키징은 완료하지 않는다. 이 후보는 push/merge/서명/설치/실기 검증을 수행하지 않았다.
