# iPad Sentry 소비자 원장

작업 키는 `ipad-sentry-control-20261025`이다. 단독 소유 워크트리는 `/Users/ambrion/.codex/worktrees/ccr-ipad-sentry-control-20261025`, 브랜치는 `codex/ipad-sentry-control-20261025`, 기준은 `e88f8dc0e48bb9a75ebdadb9d66f68fef547fd36`이다. 부모의 `deab1b282c0a1686f90ff8f717f2d957c1b9fddd` 통합은 별도 작업이며 이 워크트리에서 rebase/cherry-pick하지 않는다.

## Pstack Feature 진행

1. `how` over the affected subsystem. 완료. `WindowList`는 `Switcher.swift`의 Codable 모델이다. 수신 큐가 decode한 뒤 main에서 현재 connection을 다시 확인한다. 별도 Sentry decoder가 같은 원본 catalog의 `sentry`만 읽으므로 손상된 Sentry가 영상 catalog decode를 막지 않는다. `connection` setter가 관찰과 제어 context를 즉시 무효화한다.
2. `architect` for parallel design exploration. 사용자 ARENA 금지에 따라 후보 경쟁을 하지 않는다. 정해진 `unknown/reported` 상태와 peer/boot/session 범위, 별도의 요청 상태를 그대로 사용한다. how/architect의 추가 에이전트 도구는 이 세션에 없으며 독립 검수는 부모가 수행한다.
3. Write the throughput checkpoint as four todo items.
   - **Blocking first steps.** clean e88와 적용 AGENTS·최신 결정을 확인했다. Host213 긴급 구간을 보호하며 기기·네트워크·권한·설치·키체인을 실행하지 않는다.
   - **Independent workstreams.** 원 부모와 별도 WT로 독립 구현한다. 부모 검수·SDK는 앱 소스 동결 뒤 병렬 실행할 수 있다.
   - **Shared mutable state.** 이 WT의 소비자와 검사만 쓴다. Host·원66 서명·다른 담당 변경은 보존한다. Protocol의 유일 예외는 부모가 지정한 두 enum case와 방향별 cap이다.
   - **Smallest safe decomposition.** 관찰·제어·wiring·UI는 하나의 상태 계약이므로 이 담당이 한 번에 구현한다. store closure로 실제 UserDefaults 없이 실패를 주입하며 추가 프레임워크나 timer를 만들지 않는다.
4. Delegate code-writing to a subagent. 별도 WT를 받은 구현 담당이 직접 작성한다. 부모가 비작성 독립 검수를 맡으므로 이 담당의 자가 검토를 CLEAR로 세지 않는다.
5. Verify on the matching surface. 실제 Swift 모델·소비자·frontend 함수·MessageReader를 메모리 stand-in으로 실행하고 실제 iOS/Vision wiring을 정적으로 대조한다. SDK/UI/실기기는 이 검사의 수용 범위가 아니다.
6. Rebase into small, ordered commits. skip. 사용자 지시로 직접 커밋·rebase·cherry-pick하지 않는다. diff와 freeze 영수증을 부모에게 반환한다.
7. If the design is contested, `interrogate` before shipping. skip. 제공 계약을 구현하며 미확정 Host 소스를 대체 발명하지 않는다. 독립 검수는 부모 소유다.
8. Run **Opening a PR**. skip. 이 작업은 소스·검사 인계이며 통합·배포 권한이 없다.

Ponytail full을 적용했다. 기존 `SentryState`·JSONDecoder·StreamMessage를 재사용하고, 관찰은 typed state로 모델링했다. Boundary Discipline에 따라 wire 검증을 소비자 경계에 모았다. 입력 epoch/fence, 오디오 credential, Host 코드는 변경하지 않는다.

## 확정 계약과 소비자 정책

- 부모 계약 원장은 `/Volumes/BT-Workspace/Development-Archives/ccr/ccr-local-only-input-20261025/sentry-control-contract-v2.json`이다. 최초 읽기 시 `sourceCommit=null`이었다. 후속 직접 지시가 성공 code와 새 session 조회 규칙을 확정했다. state.version은 1, optional control.version은 2다. code는 필수 nonnull String이며 operationState와 고정 code를 함께 검증한다.
- native kind213 `activateSentry`와 kind214 `sentryState`, client 512 bytes/host 4096 bytes cap 및 반대 방향 거부는 `e9c556f8cd610414df7340074ed30073e9f11fec:Sources/StreamProtocol/StreamMessage.swift`의 원문을 읽어 지정된 구문만 포트했다. MessageReader는 기준 원문을 유지한다.
- 관찰은 수신한 보고다. v1에는 공통 monotonic 필드가 없으므로 revision UUID·벽시계로 신선도나 실제 보호 효과를 판정하지 않는다. 같은 peer의 boot/session 충돌은 연결 교체 전까지 미확인이다.
- control 없음·손상·미지원 version·다른 role·canSet=false는 조회만 허용한다. v1 자동 on이나 off fallback을 새로 추가하지 않는다. ownerDevice/canSet/authGen 광고와 현재 등록 Mac/pin, TLS sill/1, 현재 DeviceIdentity의 공개 fingerprint를 모두 검사한 명시 버튼만 요청을 만든다.
- `Sill.sentryPending.v2` 하나에 MacID/pin·기기 공개 fingerprint·원래 JSON bytes를 보존한다. secret·private key·audio credential은 저장하지 않는다. store.save 성공과 readback 일치 전에는 전송 bytes를 반환하지 않는다. 재조회는 직렬화하지 않고 저장된 원문을 그대로 사용한다.
- pending·unknown 상태의 원요청이 있으면 새 명시 on/off도 막는다. boot/authGen/Host/device가 바뀌어 원요청을 조회할 수 없어도 이 차단은 유지한다. 자동 새 ID·자동 토글·자동 원문 재전송은 없다. 같은 boot/기기/authGen을 현재 TLS와 capability로 확인한 수동 결과 조회만 새 session에서 원문을 재전송한다. 종결 applied/rejected/superseded 뒤에는 다음 명시 요청을 허용한다. 종결 원문은 다음 명시 요청이 내구 저장에 성공할 때까지 유지한다.
- applied는 accepted=true이고 desired=false이면 requested=false/phase=inactive, desired=true이면 requested=true/phase=userSessionProtected일 때만 인정한다. 현재 peer/Host/device/authGen/scope가 맞아야 한다. pending·unknown·superseded·rejected는 ON/OFF 완료가 아니다. 무효 응답은 unknown이며 credential 만료나 새 ID 재시도로 바꾸지 않는다.
- timeout은 기존 link 측정 tick의 monotonic 시간을 사용해 요청 대기만 해제한다. 이 시간은 Sentry 보고의 신선도나 권한 판단에 쓰지 않는다. 새 timer는 없다.
- off 요청은 화면 보호와 로컬 HID 차단 해제 의미만 갖는다. OS/TCC/오디오 복원 코드는 없다. Host의 manual off 유지·실제 보호 readback·Sentry authority 발급은 Host 담당 책임이다.

## Host exact 소스·fixture 수령 후 검증 계획

현재 Request/Reply/Control/Report는 제공 계약의 private 소비자 형태다. Host가 authoritative Swift 파일·commit/tree·SHA와 JSON fixture를 반환하면 먼저 그 SHA를 대조한다. `IPadSentryControl.swift`의 private DTO와 packet decode 경계만 exact 공통 DTO로 교체하고 관찰·요청 상태·store·UI 정책은 유지한다. `Sources/StreamProtocol/Sentry.swift`는 이번 담당이 수정하지 않는다.

fixture의 on/off·pending·거절·superseded·unknown을 그대로 소비자에 넣고 현재 합성 회귀의 실제 expected와 대조한다. JSON key 정렬은 서명 근거가 아니며, 재조회 원문 bytes가 바뀌지 않는지는 별도로 검사한다. v2 request UUID lowercase, authGen canonical, packet512/reply4096 및 조기 framing 거부도 exact source에서 재검증한다. Host source SHA 불일치나 fixture 부재는 계약 소스 수용 대기로 남긴다.

## 완료 경계

실행 명령은 `python3 -B Tests/checks/ipad-sentry-observation/run.py`다. 검사 로그·결과와 source freeze/SDK-ready 표식은 `.build/checks/ipad-sentry-observation/`에 둔다. 이 담당은 직접 커밋·SDK 설치·앱 실행·기기 조회·실제 송신·Keychain 쓰기·권한 변경·Host 변경을 하지 않는다.

부모의 독립 검수와 iOS SDK 빌드, authoritative Host DTO/fixture 수용, 설치와 실물 UI·접근성 검증은 별도다. Sentry 소비자 구현·모델 검사는 통화 제어, 실제 마이크/스피커 입출력, 실제 재접속이나 제품 전체 완료를 뜻하지 않는다.
