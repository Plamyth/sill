# iPad Craft 연결 제어 격리 검사

Pstack Feature의 작성 역할과 Ponytail full을 적용한다. 기존 순수 모델·desiredAudioStore·applyAudioRoutes·인증된 viewer catalog를 재사용하고 별도 통화 상태를 만들지 않는다.

1. `how` over the affected subsystem. 기존 TLS pin 확인 → viewer catalog → 선택/오디오 준비 → 공통 DTO 송수신을 읽었다.
2. `architect` for parallel design exploration. skip: ARENA·추가 agent 금지. 부모가 계약·독립 검수·SDK·통합을 소유하며 단일 writer가 확정 타입을 직접 연결한다.
3. Write the throughput checkpoint as four todo items.
   - Blocking first steps. clean base 4bcacf575a75e0297e5a7c37821c2e96b21585d6/tree d82bd7359116e845a563fec811743d902610d9ac와 계약 hash를 확인했다.
   - Independent workstreams. 이 writer는 앱/순수 상태/격리 검사, 부모는 wire delta·SDK·독립 검수·통합이다.
   - Shared mutable state. 전용 WT 단독 writer다. Host·기기·네트워크·키·오디오·설치·공유 runtime을 조작하지 않는다.
   - Smallest safe decomposition. 기존 모델에 원 operation 복구/조회 해소만 보강하고 앱 adapter와 순수 journal/session만 추가한다.
4. Delegate code-writing to a subagent. 이 위임의 작성 담당으로 직접 구현한다. 추가 agent 금지.
5. Verify on the matching surface. `python3 -B Tests/checks/ipad-craft-connected-control/run.py`로 production 코드를 컴파일해 실행한다. 실제 앱 UI·네트워크·오디오 수용은 부모 후속이다.
6. Rebase into small, ordered commits. 소유 파일만 검증 후 한 commit으로 반환한다. 기준 공통 DTO/문서는 수정하지 않는다.
7. If the design is contested, `interrogate` before shipping. skip: 확정 계약을 소비하는 범위다.
8. Run **Opening a PR**. skip: push/PR·공식 통합은 부모 소유다.

외부 경계는 `ConfiguredCraftActionControl/State.decode`만 사용한다. 기존 모델 UUID 인코딩을 직접 송신하지 않고 공통 DTO 생성자로 소문자 UUID/양수 issuedAt을 만든다. 결과 reason은 원문 그대로 내부 모델로 bridge한다. c40e367e 계약 원문과 60d0643c DTO를 보존하며 후속 nested reason256 delta는 부모가 소유한다.

저널은 그림/설정과 분리된 Application Support의 `ConfiguredCraftAction/unresolved-v1.json`에 atomic 저장·synchronize·readback한다. public MacID/pin/deviceID와 원래 요청만 보존한다. 연결 generation·TLS key·session·음성 원본은 없다. 불명 상태·쓰기 실패를 새 invoke로 우회하지 않는다. query는 같은 소유자의 명시적 원 operation만 읽는다.

외부 error는 아직 확정 notSent와 송신 뒤 unknown을 구별할 수 없으므로 원 operation을 보수적으로 유지한다. 최종 Host delta가 확정 notSent 의미를 전달하면 원 operation 종결과 다음 명시 행동 허용을 부모가 연결해야 한다. `operation_not_found`나 기타 error code의 뜻을 추측해 clear하지 않는다. 이 후속과 nested reason delta는 현재 단위의 미확정 계약 항목이다.

기존 선택 기록은 OFF를 포함해 보존한다. 신규 자동 forwarding 저장은 명시 선택이 아니다. legacy 기록은 과거 explicit OFF와 자동 기록을 구별할 수 없어 보수적으로 보존한다. 네트워크 송신·OS 권한 요청은 검사에서 호출하지 않는다. production 순수 상태와 실제 파일 journal·실제 UserDefaults의 격리 namespace를 사용한다.

최종 production 격리 검사 126개가 통과했다. 실제 `IPadAudioForwarding`의 ON→OFF 전이와 fresh/stale OFF, 기존 `IPadProviderCall`의 retained terminal/pending/unknown/active, 파일 journal의 앱 재시작 복구/명시 query/no invoke를 포함한다. `INPUT_SOURCES_UNCHANGED=true; SCRATCH_REMOVED=true`를 확인했다. 앞선 103/118개 결과는 보강 전 이력이며 합산하지 않는다.

기존 `python3 -B Tests/checks/ipad-configured-craft-action/run.py`도 실제 production 모델 309검사와 소스 불변·scratch 정리를 통과했다. 이 검증 뒤 해당 모델 코드는 바뀌지 않았다. `plutil -lint iOSClient/Sill.xcodeproj/project.pbxproj`, 변경 UI/adapter의 `swiftc -frontend -parse`, `git diff --check`도 통과했다. 이후 이 README에 결과만 기록했다.

부모는 최종 commit의 iOS SDK/full app, 기존 audio-forwarding/desired-audio/chooser harness 호환 수정과 검증, 독립 검수·공식 통합을 소유한다. 실제 UI 긴누르기·권한 복귀·연결·기기 오디오·Host 설치·음성 수용은 이 검사로 확인하지 않았다. push/PR·기기/Host·실제 네트워크/키/권한/오디오 조작은 실행하지 않았다. Pstack Model the Domain은 session/exchange/unresolved 상태로, Test Behavior Not Implementation은 앱이 사용하는 production 함수의 실제 반환·저장·readback 검사로 적용했다.


## capability 2 후속 검사 범위

2026-11-06 별도 iPad 소스 작업은 기존 상태 모델과 journal을 유지하면서 정확한 capability 1/2 허용표, 검증된 Sentry owner, revision/authGeneration/boot/session 변경, Main 발행 전 network gate 취소, 원 ID UNKNOWN/query-only 보존, 인계 후 fresh catalog 회복을 검사한다. 실제 owner 판정에는 `IPadSentryControl`을 사용한다. 인증 복귀의 로컬 취소 후 미확정 차단은 별도 기존 `ipad-sentry-return` actual consumer 검사에서 다룬다.

외부 wire·공유 host·기기·오디오·키 효과는 만들지 않는다. 이 검사와 iOS SDK 성공을 실제 통화·지속 오디오·설치 수용으로 확대하지 않는다. 현재 작업의 authoritative 진행·결과는 기존 프로그램 원장 `rea-completion-20261028/program/CURRENT-RESUME.md`에 연결한다. 위 초기 위임과 검사 수는 당시 이력이며 현재 실행 결과는 별도 exact-source 영수증을 따른다.
