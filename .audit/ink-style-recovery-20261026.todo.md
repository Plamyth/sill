# Pstack Bug fix

- [x] Reproduce it yourself on the matching surface via the driver skill (Non-negotiables), even when a debug or instrumentation protocol says to ask the user to reproduce. Ask the user only with a stated, specific reason the control surface cannot reach the target, and only after driving it as far as it goes. If it won't reproduce directly, synthesize the trigger, tighten conditions, or instrument until it fires.
- [x] Binary-search the cause. Form the candidate hypotheses, then rule them out until one survives. Seed them with `how` over the affected subsystem and the **why** skill for regression history. Each pass, take the split that cuts the most remaining problem space, get runtime evidence, eliminate. When program state is unclear, add instrumentation or logging and read it as the code runs. Don't guess. Drive a long or stubborn hunt with Claude Code's `loop` skill. Confirm the surviving *mechanism* with runtime evidence before the step-3 architect/interrogate fan-out.
- [x] Plan the fix. If it crosses a function boundary, `architect` first. Delegate implementation to a subagent using your configured bug-fix model (default in poteto-mode's Models section) with a specific scope.
  skip: 중첩 agent와 ARENA는 사용자 금지다. 직접 how 분석과 자료형·최소 설계를 기록한다.
- [x] Verify on the same surface. The original repro now passes. "Inconclusive" or wrong-surface is not a pass. Flag it. Unit tests show branch behavior, not bug absence.
- [x] Stage the commits so the failing repro lands before the fix in git history. See the **tdd** skill for the failing-test-first cadence when the bug has a cheap local test path. Skip it when the test would be expensive, integration-heavy, or unclear.
- [x] Run **Opening a PR**.
  skip: 이번 요청은 전용 WT의 commit clean 반환이다. push·PR·통합·설치·서버 실행은 부모 범위다.

# Architect

- [x] Ground.
- [x] Sketch.
- [x] Agree. 사용자 지정 범위 안에서 직접 최소 결정을 기록한다.
- [x] Implement.
- [x] Scrap. 실행 근거가 설계를 반박할 때만 재검토한다.

# 반환 조건

- [x] P2 스타일 actual Store 반례 RED → GREEN.
- [x] P2 실패 편집 후 기존 undo/redo 왕복과 native 대입의 영향 확인.
- [x] source/native/실제 ObsidianVault 파일/SDK 검사.
- [x] Mini 입력 해시와 cleanup 확인.
- [x] 자체 검토와 독립 검수의 상태 구분.
- [x] 관련 파일만 커밋하고 clean HEAD/tree·해시·리스크 반환.

BLOCKED: independent review. 이전 검수자 CLAIM 이력과 그 반례의 현재 소스 재실행만 존재한다. 새 독립 CLEAR·통합·설치는 실행하지 않는다.

최종 commit clean readback과 HEAD/tree는 외장 반환 result.json이 기록한다.
