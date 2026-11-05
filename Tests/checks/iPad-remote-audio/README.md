# iPad remote audio opt-in

This sidecar starts at `951af410413493816d10a40acf8fc3e93cabe6f2`. Its owned paths are `iOSClient` and this directory. Host, shared protocol, relay, and Vision code are outside its scope.

The settings panel shows Mac audio only after the current connection advertises `WindowList.remoteAudio == 1`. A tap sends kind200 ON with a fresh UUID. The controller discards kind33 until the same connection returns kind201 ON with that UUID. Pending consent has a six-second deadline. OFF, deadline expiry, source selection, observed source change, capability loss, connection loss, and handover revoke local consent. OFF has a separate UUID and stops the player immediately. A new connection starts without capability or consent.

`IPadRemoteAudioController` owns the consent states and effects on main. `StreamClient+Audio` passes actual message origin into that controller. Audio commands use the original NWConnection directly because SessionLink migrates held ordinary input to another connection. The decoder epoch remains locked through sample append. OFF clears samples and stops the engine before it returns, so an old decode cannot refill a stopped player.

## Reproduce the checks

Run `Tests/checks/iPad-remote-audio/run.sh --mutants` from this worktree.

The check compiles the actual production controller. `fixture.py` extracts the real StreamClient controller initialization and connection setter and compiles the entire audio adapter with fake peer, transport, and player objects. The resulting executable tests capability, explicit consent, current peer identity, matching ACK, stale ACK, packet admission, distinct OFF UUIDs, deadline, source changes, replacement, and disconnect. Eleven supplementary textual checks confirm that the main client and settings panel call these components. Those textual checks are not the behavior proof.

`player-fixture.py` compiles the real player receive, stop, and append methods. It replaces the AVAudioEngine setup and AAC decoder with fakes. A semaphore holds an encoded decode across OFF, then verifies that its late samples cannot refill or restart playback. This tests queue invalidation and immediate stop, not AAC fidelity, AVAudioSession routing, render callbacks, or audible output.

The mutation run removes individual consent, origin, source, deadline, packet, and stop protections. Each mutant must compile and fail a behavior assertion. Compiler failure and unrelated crashes do not count as caught mutants.

For an unsigned iOS build, run the following command. It does not install or launch the app.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project iOSClient/Sill.xcodeproj -scheme Sill -configuration Debug \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath .build/ipad-remote-audio -jobs 2 CODE_SIGNING_ALLOWED=NO build
```

## Design and verification limits

The pstack how pass traced the existing network queue, main-thread publication, connection handover, player queue, and shared settings panel. The architect pass compared a reducer plus effect interpreter with one callback controller. A sequential exploration was used because nested agent tools are unavailable. The callback controller keeps request ownership and the actual effects in one testable object. Model the Domain shaped the status enum. Test Behavior, Not Implementation shaped the packet and transport assertions. Prove It Works requires the executable tests and the real unsigned iOS build.

The work is disjoint from main's host changes. One owner keeps the iPad control, network origin, player invalidation, and UI changes coherent. The Mac build slot was idle before the unsigned iOS build. No nested independent reviewer is available. Independent review belongs to the integrating owner and remains pending.

Physical installation, audible playback, speaker and microphone routing, background behavior, network performance, and Mac video and touch interaction on a device remain unverified here. Video and input handlers remain in the build. The adapter's behavior check confirms that frame messages bypass the audio handler. This sidecar does not close any open host lifecycle review.

## 2026-11-05 실제 destination 복사 레벨 계측

기준은 공식 `6fb1c95f0933446b6044e9d32d1beffff0125747` / tree `d98104aa0e8dedda0c3b1188ad01231eaaaacb75`다. 소유 WT는 `/Users/ambrion/.codex/worktrees/ipad-render-levels-20261105`, branch는 `codex/ipad-render-levels-20261105`다. Pstack feature 절차와 Ponytail 최소 구현으로 기존 `RenderCounters`·player callback·metadata snapshot·player fixture를 재사용했다. 선행 기준/clean 검사를 마쳤고, 결합된 두 제품 파일은 한 소유자가 수정했으며, 공유 상태는 기존 lock 안에서만 갱신한다. 별도 fan-out은 없고 새 독립 검수는 부모가 맡는다. ARENA/순정 Goal은 사용하지 않았다.

제품 변경은 `RemoteAudioPlayer.swift`와 `IPadMicrophoneCapture.swift`뿐이다. callback에서 `destination[frame]`을 쓴 직후, 현재 formatVersion의 실제 source 샘플 복사에만 `finiteCopiedSamples`·`nonzeroCopiedSamples`·`copiedSampleSumSquares`·`copiedSamplePeak`를 누적한다. nonzero는 유한한 0이 아닌 Float 표본 수다. NaN/Inf는 집계에서 제외하고 실제 재생 샘플은 바꾸지 않는다. 제곱은 Double에서 계산하며 표본 수 포화 시 집계를 멈춰 분모 wrap을 막는다. RMS는 기존 main snapshot에서만 계산해 `render.copiedSampleRMS`로 출력한다. 복사 관측이 없으면 null, 유한한 0만 복사됐으면0이다. attempt/formatVersion 범위와 기존 possibly-retired 표시를 유지한다. 새 tap·원음 보관·권한·라우트·OS 세션·callback I/O·동적 할당·잠금은 추가하지 않는다.

`render-levels.py`는 기존 `player-fixture.py`에 실제 AVAudioSourceNode closure를 보관하는 가짜 node/engine만 연결하고 callback을 합성 destination 버퍼로 호출한다. 받은/디코드 버퍼는 callback 전까지 집계0임을 확인한다. 실제 destination에서 읽은 제곱합/peak와 snapshot RMS를 대조하고, NaN/Inf/Float 최대값·underrun 무음 채움·stop 뒤 옛 callback·새 attempt/format 초기화·admission 기한 만료·카운터 포화를 검사한다. 테스트 버퍼 할당과 JSON 쓰기는 callback 밖에서만 수행하며 실제 AVAudioEngine·OS 세션·장치는 실행하지 않는다.

Mini 공식 ephemeral 실행에서 callback/snapshot27개와 기존 metadata identity·rate cap·attempt bound·connection reset 검사가 exit0으로 통과했다. callback에 새 lock/할당/I-O/dispatch/RMS 계산 호출이 없는지도 확인했다. 공식 영수증 `20261105T105607.059199Z-ipad-render-levels.json`의 `cleanup_verified=true`와 runner의 `scratchRemoved=true`를 확인했다. 승인 외장 `BT_CCR-ipad/render-levels-20261105/checks.log`와 `handoff.json`에 정확 소스 해시·결과를 연결한다. 이는 한시적 입력의 좁은 검사이며 Git source-guard 이전 수용이나 독립 검수 CLEAR가 아니다. integration·SDK·서명·설치·UI·Host·실기·키·권한·라우트 변경과 push/merge는0회다. 계측 결과는 실제 소리나 물리 청취 수용의 증거가 아니다.
