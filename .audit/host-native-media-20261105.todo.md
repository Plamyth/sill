# 순정 Codex 원격 음성 연결

원장은 기존 `fold-owner-connect-recovery-20261029/progress.json`이다.
이 파일은 같은 작업의 소스 체크리스트이며 권한·실제 수용 원장을 대신하지 않는다.

- [x] `how` over the affected subsystem.
  기존 Core producer, command.sock, Host subscriber/epoch, Node http PCM을 대조했다.
- [x] `architect` for parallel design exploration.
  skip: 사용자 ARENA 금지에 따라 경쟁 설계를 실행하지 않았다. 존재하지 않는
  가상 출력 경로를 제외하고 기존 IPC와 media 경계를 재사용하기로 조율했다.
- [x] Write the throughput checkpoint as four todo items.
  - [x] **Blocking first steps.** 기존 자료·실제 source·소유자와 241/243 보존을 확인했다.
  - [x] **Independent workstreams.** Swift 변환, Node http 경계, Core producer는 별도 소유 공간이다.
  - [x] **Shared mutable state.** 공식 통합·서명·실제 교체·Mac 입력/음성만 Root와 원담당이 직렬 처리한다.
  - [x] **Smallest safe decomposition.** 기존 함수 재사용을 우선하고 새 endpoint·녹음기를 만들지 않는다.
- [ ] Delegate code-writing to a subagent using your configured feature model.
  입력 변환 b6e13276은 커밋·검사 완료, 독립 검수 중이다. Node는 현재 permit에
  결속한 네 private RPC를 같은 소유 공간에서 구현 중이다. Core IPC 계약은 대조 중이다.
- [ ] Verify on the matching surface.
  실제 Apple 변환 95검사와 SDK는 완료했다. 연결된 Host/Core의 통화는 미검증이다.
- [ ] Rebase into small, ordered commits. Stack follow-ups.
  pending243 공식 ref를 움직이지 않는다. native 후속 후보는 별도로 통합한다.
- [ ] If the design is contested, `interrogate` before shipping.
  서로 다른 설명은 실제 소스로 대조했다. 공통 framing은 Core의 같은 버전 계약을 기다린다.
- [ ] Run **Opening a PR**.
  실제 caller 연결·필수 검사·독립 검수 뒤 수행한다.

데이터 모양은 `NativeMediaAttachment`의 현재 scope와 `prepared/attached/retired`
수명주기다. 원문 target/voice, 현재 forwarding binding, subscriber와 epoch를
한 결속으로 취급한다. 종료된 provider scope의 1500ms 권한을 연장하지 않는다.

종료 조건은 승인된 현재 세션의 start → microphone append → 원격 응답 audio →
stop이 같은 버전으로 관측되는 것이다. 소스·모의 검사·서명은 이 조건과 분리한다.
물리 Vision 시험은 사용자 지시에 따라 나중에 수행한다.
