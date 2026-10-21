# Cursor 로컬 원본 창 입력 후보 검증

원담당 `01a13005-ff61-7780-b0e8-6dc171de1c9d`, 작업키 `cursor-input-lease-20261021`, 기준 `a2567e7c3147512d4d79d335c4a1f13a640124d2`, 브랜치 `codex/cursor-input-lease-20261021`이다. 외장 SSD의 Git 작업트리를 사용한다. Codex managed worktree 연결은 거절되었고 Git 등록만 성공했다.

## Pstack Feature 절차

- [x] 1. `how` over the affected subsystem.
- [x] 2. `architect` for parallel design exploration.
  사용자 지시로 ARENA와 후보 경쟁은 제외한다. CCR 본체와 커널 peer·창 범위·대화 권한 미지원 경계를 합의하고 순수 모델 작성자와 OS 경계 검수자를 나누었다.
- [x] 3. Write the throughput checkpoint as four todo items.
  - [x] **Blocking first steps.** 기준 소스·현재 호스트142·호출자/프로세스 신원·Sill 우선권을 먼저 확인했다.
  - [x] **Independent workstreams.** 순수 모델 작성 완료 후 부모가 OS/통합 코드를 작성했다. Android 담당은 파일을 변경하지 않고 peer·소켓·창 경계를 검수했다.
  - [x] **Shared mutable state.** 작업트리는 작성자 반납 후 순차 작성했다. 기존 호스트·오디오·기기 상태는 바꾸지 않았다.
  - [x] **Smallest safe decomposition.** 추가 에이전트 생성/재개는 동시 실행 상한으로 실패했다. 기존 모델 작성자와 부모의 작성 범위를 나눠 독립 검수를 유지했다.
- [x] 4. Delegate code-writing to a subagent using your configured feature model.
  Heisenberg가 Host 내부 비직렬화 Connection/Grant와 lease 상태 모델을 작성·커밋했다. 부모가 실제 peer·창·소켓·Broker를 작성하고 작성자는 이 코드를 독립 검수했다. 새 후보 경쟁은 실행하지 않았다.
- [x] 5. Verify on the matching surface.
- [x] 6. Rebase into small, ordered commits. Stack follow-ups.
  원 기준 커밋 위에 모델/갱신/명시 해제와 통합 변경을 순서대로 보존한다. 공유 브랜치를 강제로 변경하지 않는다.
- [x] 7. If the design is contested, `interrogate` before shipping.
  skip: 합의한 창 범위와 미지원 대화 권한 경계에 미해결 설계 충돌이 없다.
- [x] 8. Run **Opening a PR**.
  skip: 공식 통합 담당에게 소유 브랜치를 전달하는 단계이며, 미통합 의존 기준 전체를 포함하는 PR은 만들지 않는다. PR CI는 자동 실행되므로 불필요한 유료 빌드도 만들지 않는다.
  공식 호스트 통합 담당에게 후보를 전달한다. 현재 의존 기준 a256은 공식068be8f에 아직 통합되지 않았으므로 공식 기준 PR로 다른 변경까지 한꺼번에 올리지 않는다.

## 선택과 종료 조건

Pstack의 Model the Domain 원칙으로 Host가 발급한 비직렬화 Connection/Grant와 명시적 창 범위를 사용한다. Ponytail 원칙으로 기존 InputInjector, WindowSizer, JSON 검증기와 정식 호스트 서명 검사를 재사용한다. Sill 프로토콜 번호와 전역 영상 선택은 변경하지 않는다.

코드 후보의 종료 조건은 모델83·타입 경계8, Broker21·peer6·임시 파일/소켓14, 실제 InputInjector 인가/소유 및 전송 카운트 검사, 실제 SillMenuBar 링크 빌드와 독립 검수다. 같은 조건 재조회나 heartbeat는 만들지 않는다.

실제 정식 Obsidian peer 접속, AX 창/영상 좌표, 실제 Mac 입력, 앱 설치와 원격 기기 수용은 별도다. 이 검증은 기존142 앱·S23·iPad·Vision Pro·오디오/HAL/TCC를 변경하지 않는다. Mini의 격리 fixture에서는 임시 Unix 소켓/파일만 만들고 제거한다.

## 수정 이력

최초 SDK 검사에서 Swift에 노출되지 않는 C 매크로와 SecCode/StaticCode 변환 오류가 드러나 수정했다. 최초 Broker 검사에서는 테스트 경계의 CoreGraphics import 누락을 수정했다. Android 독립 검수에서 수명 전체의 파일 잠금과 생성 FD의 fstat 신원이 필요하다고 지적해 적용했다. Heisenberg는 재전송 영수증의 observedAt 보존을 확인했다.

마지막 P2는 정리용 modifier Up만 게시됐을 때 요청 성공으로 집계되는 문제다. text 준비 해제와 preparedKey의 마지막 전 단계만 관찰에서 제외하고 명시적 요청 Up은 집계하도록 수정했다. 실제 InputInjector의 CGEvent.post 단일 경계를 테스트용으로만 차단해 OS 입력 없이 회귀검사한다.

## 최종 코드 후보 검수

모델83개와 컴파일 거절 경계8개, Broker21개, 실제 peer 거절6개와 임시 inode/프로세스 잠금14개가 통과했다. 마지막 카운트 수정 뒤 실제 grant/post24개와 실제 InputInjector dry-run24개, 단일 CGEvent.post 경계만 차단한 전송 집계8개가 통과했다. 마지막 실제 SwiftPM SillMenuBar 링크 빌드는 20261021T021131.269100Z 영수증에서 exit0이며 전체147개 제품 입력 파일의 SHA가 현재 후보와 같다. 빌드 바이너리와 Mini 한시 입력/출력은 제거하고 부재를 확인했다. 이는 실행 속도 측정이 아니다.

Heisenberg의 Protocol/Broker/Coordinator 및 최종 InputInjector 검수는 CLEAR다. Android 원담당의 Peer/UnixChannel/Window 독립 검수도 수정 후 CLEAR다. 부모는 다른 작성자의 순수 lease 모델과 거절 경계를 검토했다. 정적 검수와 직접 실행 근거를 구분한다.

초기 SDK/테스트 실패 로그는 외장에 보존했다. 최종 SDK에 이후 추가된 observedAt과 마지막 InputInjector 변경은 최종 전체 링크 빌드로 검증했다. 기존 Broker/peer 검사의 전체 입력 SHA는 마지막 후보와 같고, 카운트 변경 영향은 실제 Injector 경계 검사로 별도 검증했다. 같은 조건의 불필요한 재실행은 하지 않았다.

코드 후보 검증 단위는 끝났다. 정식 Obsidian peer의 실제 양성 접속·AX/영상 좌표·실제 CGEvent 입력·Host 설치·기기 수용은 모두 미수행이다. 실제 설치142는 그대로며 새 IPC를 제공하지 않는다. 공식 통합068be8f와 코드 후보를 구분한다. 영구 Mini 소스나 실제 오디오/HAL/TCC/기기 상태는 변경하지 않았다.
