# 자동 기기 주체 독립 부품

작업 키 automatic-device-access-20261021. 전용 브랜치 codex/host-tailnet-device-identity-20261021, 기준 fb78952bb17b996553123fea594127e990966645. 부모는 Door, StreamServer, ClientRoute, RemoteAccess와 통합·독립 검수·런타임을 소유한다. 이 작업은 지정된 새 두 소스와 새 계약 검사 및 이 audit만 쓴다.

- [x] `how` over the affected subsystem.
- [x] `architect` for parallel design exploration. 사용자 직접 금지로 병렬 탐색·ARENA·후보 경쟁은 생략하고 단일 계약을 설계했다.
- [x] Blocking first steps. 브랜치·기준·clean 상태·범위·공식 자료를 확인했다.
- [x] Independent workstreams. 이 작업은 독립 소스 부품 하나이며 부모 통합 코드와 쓰기가 겹치지 않는다.
- [x] Shared mutable state. 센서 실행은 인스턴스당 하나로 제한하고 stop·취소·늦은 완료는 단일 결과 게이트를 통과한다.
- [x] Smallest safe decomposition. 기존 IPBytes와 Foundation·CryptoKit·POSIX를 재사용한다. 새 의존성·서버·에이전트는 없다.
- [x] Delegate code-writing. 부모가 위임한 독립 구현 소유자가 직접 구현한다. 추가 에이전트는 금지다.
- [x] Verify on the matching surface. 생산 조건 typecheck와 실제 parser 계약 115개가 통과했다.
- [x] Rebase into small, ordered commits. 지정 base 위 단일 소유 커밋으로 전달한다. 원격 게시·통합은 부모 소유다.
- [x] If the design is contested, interrogate before shipping. 해당 없음. 사용자 계약을 따른다.
- [x] Run Opening a PR. 부모에게 정확한 로컬 커밋을 반환하는 범위이므로 PR·게시·통합은 수행하지 않는다.
- [ ] 독립 검수는 부모가 별도로 수행한다. 자체 검사로 대체하지 않는다.

## 구조와 계약

OriginPolicy는 주소·인터페이스의 경로 분류이며 Tailnet 사용자 인증이 아니다. IPBytes는 숫자 IP를 바이트로 정규화하므로 재사용한다. CableLink는 실제 USB ancestry와 source를 검사한다. 케이블 판정은 부모가 수행한다. AutomaticDevicePrincipal의 세 case는 값 형식이며 namespace별 SHA-256 식별자로 분리한다. localNetwork의 Data32만 실제 현재 TLS 인증서 digest를 받으며 부모가 소켓에 결합한다. 다른 case의 해시는 TLS fingerprint가 아니다.

호출 초안은 `let access = TailnetDeviceAccess(); let result = await access.principal(for: numericSocketSource)`다. 성공 proof는 `access.isCurrent(proof, sourceIP: originalSocketSource)`와 부모의 원래 연결 세대·소켓 생존 검사를 함께 통과해야 쓸 수 있다. Door 종료 시 `access.stop()`하고 재시작에는 새 인스턴스를 만든다. 앱 키·pairClaim·기기 이름으로 발급하는 경로는 없다.

Pstack Model the Domain 원칙으로 principal 세 종류, proof, 실패 원인을 타입으로 표현했다. how·architect는 사용자 금지 범위 안에서 순차 적용했다. Ponytail은 IPBytes·표준 라이브러리 재사용을 선택했다. 기존 앱 등록·paired 기록·TCC·키·런타임은 변경하지 않는다.

## 공식 근거와 보수적 호환 범위

- https://github.com/tailscale/tailscale/blob/main/tailcfg/tailcfg.go 의 Node.User는 tag 사용 시 ACL identity와 다를 수 있으므로 tag 주체를 거부한다. Node.Addresses만 직접 기기 주소이며 AllowedIPs는 라우팅 범위다. StableNodeID는 불투명 문자열이므로 특정 n-prefix 형식을 추정하지 않는다.
- 같은 파일과 https://github.com/tailscale/tailscale/blob/main/ipn/ipnlocal/expiry.go 에서 명시적 zero KeyExpiry는 만료 비활성이며 Expired는 별도 거부 조건이다. 최신 source의 omitzero는 zero field 생략을 허용하지만 이 부품은 누락·null expiry를 보수적으로 거부한다. 실제 관측된 명시적 KeyExpiry 스키마만 수용한다.
- https://github.com/tailscale/tailscale/blob/main/ipn/ipnstate/ipnstate.go 와 https://github.com/tailscale/tailscale/blob/main/cmd/tailscale/cli/whois.go 의 status/self 및 whois JSON 구조를 사용한다. status 전후 Running·Self.ID·Self.UserID가 일치해야 한다. CLI는 원자적 netmap revision을 제공하지 않으므로 동일 self snapshot 사이 peer 변경이나 ABA 전체를 증명하지 못한다. proof는 조회 시작부터 2초 안에서만 유효하다.

## 검증 경계

SDK 전체 빌드·실제 peer TLS·실기기 연결·앱 설치·기기 승인·운영 수용은 이 작업의 증거가 아니다. 외장에 좁은 Swift 계약 실행물만 만든다. Mini의 SDK 실행 문제는 부모와 Android 담당이 조율한다.

## 최종 검사 영수증

2026-10-21 KST에 아래 명령을 실제 실행해 종료 코드 0과 계약 115개 통과를 확인했다.

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash Tests/checks/automatic-device-access/run.sh --live-self
```

검사 실행물은 `/Volumes/BT-Workspace/Development-Archives/BT_CCR/automatic-device-access-20261020T230028-72282/check`에 있다. 생산 조건의 좁은 세 파일 typecheck는 테스트 DI 플래그 없이 수행했다. 계약 실행물은 `AUTOMATIC_DEVICE_ACCESS_CONTRACT`를 정의해 테스트 전용 초기화만 추가한다. 두 검사 모두 Swift 6, complete strict concurrency, warnings-as-errors, macOS 14 target을 사용했다. 전체 SillHost SDK 빌드 영수증은 아니다.

검사 범위는 세 namespace, 실제 JSON parser와 검증기, 숫자 endpoint와 mapped IPv4 및 IPv6, loopback과 hostname 거부, 주소 범위만으로 신뢰하지 않음, 사용자 불일치, 미승인·공유·tag 주체, 만료·zero time·나노초·시간대·손상 날짜, 누락·손상 JSON·출력 상한·센서 실패, 조회 전후 Self.ID·사용자·백엔드 전환, 단일 실행 슬롯, Task 취소, stop, 협조하지 않는 늦은 결과 무시, 다른 source와 발급자 proof 거부 및 proof 만료다.

실제 기본 CLI의 로컬 self 조회에서도 Running과 Self.UserID `7583687675853032`, whois StableID `nRWmCkHUn621CNTRL`, 동일 사용자, MachineAuthorized 및 KeyExpiry 검증을 통과했다. 개인키 조회나 출력은 없다. 실제 다른 기기의 peer TLS와 연결 승인·등록·TCC는 검사하지 않았다.

초기 CLT 컴파일은 결과 없이 지연되어 이 작업의 컴파일러만 종료했다. 이어진 storage-route 재실행은 기존 목적지에 대해 DESTINATION_EXISTS를 반환했으므로 그 시도는 컴파일 성공으로 세지 않았다. 스크립트는 이후 매번 도구가 발급한 고유 외장 목적지를 사용한다. 중간 실제 CLI self 조회는 2초 마감으로 미발급됐다. 별도 읽기 진단에서 첫 status가 3초를 넘긴 사실과 후속 whois·status 정상 응답을 확인했다. 최종 생산 기본 경로의 세 조회는 마감 안에 통과했다. 초기 지연의 일반적인 원인이나 모든 환경의 시간 보장은 주장하지 않는다.

프로세스는 인스턴스당 한 조회와 한 직접 자식으로 제한한다. wrapper가 실행하는 하위 CLI도 같은 전용 프로세스 그룹에 두며 취소·오류·마감 때 자기 그룹만 SIGKILL하고 직접 자식을 waitpid로 회수한다. stdout과 stderr 합산 상한은 512KiB이며 원문은 로그에 남기지 않는다. 닫히지 않은 호스트 소켓이 CLI로 넘어가지 않도록 CLOEXEC_DEFAULT를 사용한다. 절대 마감은 조회 시작부터 2초이며 호출자에게 결과를 반환한 뒤에도 회수가 끝나기 전에는 슬롯을 다시 열지 않는다.

## 부모 통합용 API

```swift
let access = TailnetDeviceAccess() // Door 수명에 하나를 공유한다.
let result = await access.principal(for: actualSocketSourceIP)
if case .success(let proof) = result,
   access.isCurrent(proof, sourceIP: actualSocketSourceIP) {
    // 부모의 원래 소켓과 연결 세대가 여전히 같을 때 proof.principal을 채택한다.
}
// Door 종료 시 access.stop()을 호출한다.
```

`busy`는 다른 조회가 실행 중이거나 회수 중임을 뜻한다. 내부 무한 재시도·대기열은 없다. 새 연결에는 새 조회를 사용한다. stop된 인스턴스는 재사용하지 않는다. proof는 조회 시작부터 최대 2초이고 peer 만료가 더 빠르면 그 전에 무효화한다. 원래 소켓의 종료·재연결·source 변경·세대 변경을 검사하고 Task도 취소하는 일은 부모의 소유다. principal은 앱 키 소유 증명이나 실제 TLS 성공을 대신하지 않는다.

LAN에서는 부모가 실제 socket TLS 인증서 SHA-256을 `Data32(actualDigest)`로 길이 검증한 후 `.localNetwork(transportFingerprint: digest)`를 만든다. 케이블에서는 기존 CableLink 판정을 거친 device ID로 `.cable(deviceId:)`를 만든다. 이 부품에는 LAN source나 pairClaim만 받아 신뢰를 발급하는 API가 없다. 부모는 LAN·케이블 principal에 Tailnet 원격 권한을 부여하지 않는다.

## 정확한 소스 해시

아래 순서로 `경로 + NUL + SHA256 hex + LF`를 UTF-8로 연결한 집합의 SHA-256은 `df32008d6ae59ce8d7c05955dc680319aa13c20ba59d0f0eb121687e15f2e4f5`다. OriginPolicy는 읽기 전용으로 재사용했으며 변경하지 않았다.

| 경로 | SHA-256 |
| --- | --- |
| Sources/SillHost/AutomaticDevicePrincipal.swift | b971777190b251adc0ef1eddecefae16a99585d777ee44a2053afc64e0745bc2 |
| Sources/SillHost/TailnetDeviceAccess.swift | 5bcc5d28d36f302944f1ec9d1e5ab142f9835310c1bff0883dde98c01bdf2f47 |
| Sources/SillHost/OriginPolicy.swift | c263125add93da1c21e1a2238a3368e85e4eca10ed6843710fa6df922ee7cda3 |
| Tests/checks/automatic-device-access/Contract.swift | 59fd503d6d1e39c873f4036342cd88943b8dc4279b0724e85cc665e4b7891ec8 |
| Tests/checks/automatic-device-access/run.sh | 0f6398b4834bb2e3df773c05ddab5680fa2e286a2989c91411701651c0cb6453 |

소유 범위 자체 diff 검토에서는 기본값에 테스트 센서를 연결하지 않음, 다른 소스·기존 paired 기록을 쓰지 않음, App 키와 TLS fingerprint를 Tailnet identity로 위장하지 않음을 확인했다. 이 검토는 부모의 독립 검수와 통합 수용을 대신하지 않는다. 최종 커밋은 인계 답변으로 제공하고 이 작업의 쓰기 권한을 부모에게 반납한다.
