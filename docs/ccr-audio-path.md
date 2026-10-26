# CCR Sill audio path

## 현재 원격 음성 계약, 2026-10-25

원격 음성은 `AudioForwardingIntentRequest`와 공통 Node 권한 원장 하나를 사용한다. 기기를 전환할 때 호스트는 기존 미디어를 먼저 차단하고 두 참여자의 정지 영수증을 확인한 뒤 새 바인딩을 승인한다. 연결 종료는 기억한 입출력 의도와 로컬 보호를 해제하지 않는다. 같은 기기의 재접속도 현재 신뢰와 새 전송 바인딩을 확인해야 음성을 재개한다.

`HostAudioPrivacy`는 승인된 가상 경로를 제외한 모든 로컬 장치의 입력과 출력을 검사한다. 일반 음소거가 있는 방향에는 `masterMute`를 적용한다. 일반 음소거가 없는 방향은 장치 소유권, 스트림 식별자, 방향, 형식과 전체 채널 범위를 확인한 뒤 모든 스트림을 비활성화하고 다시 읽는다. 카탈로그의 방식 이름은 `audioStreamInactive`다. 미확인 장치나 불완전한 범위는 `unsupported`이며 전체 원격 음성을 승인하지 않는다.

원래 장치 상태는 HAL 쓰기 전에 저널에 저장하고 동일 바이트로 다시 읽는다. 연결 종료와 일반 정지는 로컬 입출력을 복원하지 않는다. 로컬 복귀에는 새 macOS 인증, 양쪽 참여자의 실제 정지 확인과 현재 공통 원장의 전환이 필요하다. 복원은 저장한 원상태만 사용한다.

2026-10-26 명시된 원격 연결·선택형 Sentry·오디오 소유권은 독립이다. 인증된 로컬 복귀는 원격 오디오 의도를 종료하고 저장한 Mac 장치를 복원하지만, 일반 원격 화면 연결을 전부 종료하는 명령은 아니다. 같은 연결에서는 영상·캡처와 Sentry 세션 ID를 보존하고, 인가·상태·선택 세대를 갱신하며 미완료 요청을 폐기해 복귀 전 명령을 재생할 수 없게 한다. 실제 연결이 교체되면 세션 ID도 새로 발급한다. 인증·미디어 정리 중에는 기존 차단을 유지하고, 완료 뒤 명시적인 새 Sentry 선택만 수용한다.

사용자가 2026-10-21 04:08:36 KST에 지정한 음성 소유 규칙은 요청한 한 기기를 기억하고 다른 기기의 새 요청이 없으면 재접속을 이어가는 것이다. 단순 추가 연결이나 조회만으로 소유자를 바꾸지 않는다. 예상 밖 네트워크 단절과 사용자의 명시적인 로컬 복귀·사용 종료를 구분한다. 출력 다중 송신을 별도로 합의했다는 원문은 이번 대조에서 확인하지 못했으며, 현재 공통 원장은 양방향에 하나의 pairedDeviceId와 binding을 사용한다.

통화 명령은 미디어 전송과 구분한다. `221/222`의 실행 대상은 ChatGPT Dots이며 순정 Codex 데스크톱 통화의 실행기로 해석하지 않는다. 현재 순정 데스크톱의 특정 통화를 조건부로 시작하거나 종료하고 마이크 해제까지 확인하는 producer는 연결되지 않았다. 공개 CLI 요청 형식만으로 해당 데스크톱 통화를 제어할 권한을 만들지 않는다.

DN32-LIVE의 입력과 출력 각 32채널 스트림은 읽기 전용으로 관측했고, 생산 HAL과 저널은 주입 장치로 검사했다. 실제 스트림 쓰기, M32R의 물리 스피커 무음, 기기 간 통화 전환과 프로세스 종료 뒤 보호 지속성은 별도 실물 수용 항목이다. 소스 검사와 서명 후보는 이 수용을 대신하지 않는다.

## 과거 구현 기록

아래 기록의 로컬 출력 유지와 재접속 시 수동 음성 선택은 당시 실험 조건이다. 현재 계약은 위의 원격 보호와 바인딩 규칙을 따른다.

## Intended behavior

The iPad plays the Mac's sound while the Mac keeps its current output device and volume. The iPad user turns remote sound on or off. Audio must stop when the Sill session ends. A later microphone path must bind input to the intended Codex voice session or an explicit Mac input device.

## Current source

Commit `89f9550` adds kind 33 `AudioPacket` decoding and `RemoteAudioPlayer` to the iPad fork. That iPad target built with a valid signature, but this source has not been installed or heard on the iPad. The installed iPad build still has working video, touch, Pencil, and recipient selection. The current host candidate compiles and the 200 protocol checks pass; no host audio candidate is installed yet.

## Host capture choice

Two routes were considered. Adding audio to the video `WindowCapture` stream would share its capture filter, but every source switch would stop the audio stream. A window filter may also omit audio from other apps on the Mac. A separate ScreenCaptureKit audio stream keeps sound stable while video sources change. It can capture without changing the Mac output route or muting apps. Use that route for the first host implementation.

The host advertises `WindowList.remoteAudio = 1`. The device sends kind 200 `RemoteAudioSubscription {enabled, requestID}` only after a user action. The host echoes that ID in kind 201 `RemoteAudioState`; a revocation caused by source change or capture failure has no request ID and never grants sound. The iPad must ignore a late enable answer whose ID no longer matches its pending user action. On every new connection and source change, sound returns to off and requires a new opt-in. Backgrounding stops the iPad player and sends off where possible; reconnection never resumes sound automatically.

The host captures with a separate ScreenCaptureKit stream and leaves the Mac's output route and mute state unchanged. The server sends kind 33 only to currently subscribed connections, drops audio for a client with more than 512 KiB of pending network data, and increments a capture epoch on source change. A callback from an old stream is discarded if its epoch differs. Each new opt-in takes a serial capture-queue boundary, discards a partial PCM packet, and admits only packets captured after that boundary for that client. Subscription changes and state answers use the same ordered network queue. Capture failure and normal stop both drain the PCM queue before another opt-in can start. Every ON or OFF advances a host action serial even if the client reuses the same request ID, so a delayed ON cannot undo a later OFF. An idle stop checks for new subscribers before stopping; a pending stop also bars a new enabled answer until the stop finishes and capture is checked again. The iPad clears its jitter buffer on disconnect and format change. Captured samples and microphone data are never written to disk by this path.

Do not merge the whole upstream Sill PR #66 audio path. Its process tap uses `mutedWhenTapped`, which would mute the Mac output. The upstream packet shape and AAC-ELD decoder are reusable; the host capture and user control need separate implementation.

## Remaining proof

1. Check the host capture callback with consented local sound and inspect its permission behavior. Compilation and protocol checks do not prove audible sound.
2. Add an explicit iPad sound control and a capability-bound subscription. Prove that older Sill hosts and clients keep video and input working.
3. Install a separate host candidate only after source and input review. On the physical iPad, hear the Mac sound, check that the Mac still plays through its chosen output, then switch video sources and reconnect.
4. Measure sound delay and test a slow link. Verify that audio drops instead of piling up and that video remains responsive.
5. Design the microphone destination with an exact voice-session or input-device binding. Test microphone permission, route changes, echo cancellation, and reconnect before calling two-way sound complete.

## Microphone owner decision, 2026-10-16

The current source has a host receiver and a virtual-device HAL sink, but the production `SillMenuBar` coordinator is created without a `HostMicrophoneOriginalOwner`. Its `WindowList.microphone` capability is therefore absent. The receiver checks the paired peer, encrypted route fingerprint, source, input generation, video epoch, destination, call generation, and expiry before admitting PCM. The sink also verifies the approved virtual device UID, plug-in, channel layout, and 48 kHz format. These checks do not identify which Codex voice call owns that device.

Two owner shapes were considered:

1. Infer ownership from the Control Room `activeVoiceSession` snapshot and CoreAudio's Codex process input state. This can observe a candidate call and current input device, but neither read is an atomic authorization. A closed call and a new call in the same process could occur between reads. This shape must not mint a host grant.
2. Have the original voice-call owner issue a lease containing its exact call generation, approved input device, and revocation event. A single Mac-side owner object would expose only `microphoneGrant(...)` to `StreamCoordinator`; it would synchronously revoke all issued `HostLocalOwnerGrant`s before a call, route, or device generation changes. The CoreAudio process probe can independently reject a mismatched route, but cannot create the lease. This is the selected integration shape.

Caller usage is `StreamCoordinator(..., microphoneOwner: owner)` only after that owner is backed by a live original-call lease and the virtual input route is explicitly approved. With no lease, the provider returns `nil`, the catalog advertises no microphone capability, and the iPad cannot start capture. Tests must prove no lease means no capability, a changed call or route revokes an old render grant, and a new call cannot inherit the prior peer or packet sequence. The read-only `Tests/checks/microphone-route/ProcessProbe.swift` currently reports the Codex process input state and device UIDs; its idle result is not a voice-call receipt.

The missing input is an authoritative call-generation/revocation event from the Codex voice owner. Until it exists, keep production microphone routing off. Audit the existing BlackHole devices' S23 and system-output users before dedicating any virtual input to Sill. The original Sill installation and Mac sound routes remain untouched.

## Host continuous-voice candidate, 2026-10-16

The first host receiver retained only the latest microphone frame, so five 20 ms frames arriving together could lose four before the MainActor drain. The candidate now preserves up to six ordered frames in ingress and six packets in the render buffer. A normal 100 ms five-packet burst can begin playout after a 50 ms application delay and finish before the 160 ms per-packet residence limit. The buffer supports partial HAL pulls across packet boundaries. On overflow it discards the oldest packet and increments saturating local counters; on expiry it discards stale packets. Stop, grant revocation, peer loss, and source change close the render gate and remove queued audio.

The exact candidate source built as `SillHost`; the inert host harness passed 362 assertions and caught all 18 compiled fault variants with source unchanged. The harness used distinct sample values to check five 960-frame packets in order, a delayed start, partial reads, ring wraparound, overflow, expiry, and post-stop silence. It also parsed five consecutive framed microphone messages through the host receive loop and retained their sequence before the bounded ingress drain. This is source and fake-device evidence, not a native audio or Codex call receipt. The independent review found a remaining real-time tradeoff: rendering uses a nonblocking lock and can output silence if a producer happens to hold the ring lock. Decoding is outside that lock and the protected copy is bounded, but no zero-glitch guarantee is claimed. TCP/OS buffering and the original-call owner route still require separate measurement and approval.

## Separate Mac host trial

The installed `/Applications/Sill.app` has bundle ID `me.saffer.sill.mac` and a Developer ID signature from team `9B2KKVM937`. The CCR fork is signed by team `ZPTXHJ866D`; it cannot inherit the original app's protected keychain access group. Launching a same-ID development build is also ambiguous for TCC, login items, and pairing. The trial therefore packages `CCR Sill.app` with bundle ID `com.ambrion.sillcanvas.mac`, its own UserDefaults domain, log path, and keychain item service/tag. The original bundle keeps the historical keychain names exactly. The two host identities require separate pairing; no original key, cookie, trust list, or session is copied. The new package stays in `.build`, and its script never installs or launches over original Sill.

Two package shapes were considered: (1) temporarily replace the original Sill process with a same-ID binary, reusing its pairing, or (2) run a distinct CCR bundle and pair it independently. The first interrupts the user's current projection and crosses a signing/identity boundary. The second keeps the original installation and pairing intact and is the selected trial shape. Before a physical audio check, verify the fork's bundle ID and signature, start it without changing the original app, grant Mac screen/audio permissions only to that fork, pair the iPad to the fork as a separate Mac entry, and confirm video/touch before enabling Mac sound. Observe actual iPad speaker output, the Mac output route, reconnect, and log/latency; then stop the fork and confirm the original pair still connects. No successful source build or signed package alone counts as audible sound.

## iPad batch sender adoption

The Vision owner published source commit `ecdc89d81e632fab6a9b55a3052b976bad52a263` and source receipt `vision-microphone-client/source-receipt.json`; live source verification passed. Only its shared `IPadMicrophoneCapture` worker, `IPadMicrophonePCM`, `IPadMicrophonePolicy`, and `IPadMicrophoneFrameGate` changes were adopted. The iPad-native capture's callback now carries a complete conversion batch to `FrameGate.emitBatch`, which serializes up to the bounded batch into consecutive kind-206 messages in one network send. The old one-frame API remains for compatibility but is not used by the native capture path. A local gate check parses five messages from that one serialized send and checks sequence, scope, grant, and exact end offset. The owner separately passed 437 software checks and 17 compiled mutants; those are its source result, not a physical iPad or host receipt. This iPad branch's policy, PCM/conversion, and gate checks and signed generic iOS build passed after adoption. Device installation, native microphone capture, and exact-call routing remain separate gates.

The isolated host also has a candidate `CCR Sill` suffix for its Bonjour and authenticated Mac name, preserving the stock name for the original bundle. It compiled into a separately signed host package and that package started. The physical iPad's cable discovery list still displayed the Mac's two old names, even after restarting the iPad client; the suffix is not accepted as visible UI behavior yet. The fork was at 0 paired clients and Screen Recording off. Diagnose which advertised/cable record the row uses after permission before claiming the name change works.

## iPad virtual input lifecycle candidate, 2026-10-18

Task `ipad-microphone-plugin-20261017` owns the exclusive branch `codex/ipad-microphone-plugin-20261017`, based on `cbaf99ceead29923f2c326a4e267ba0b9e39130e`. This section describes source behavior; parent hardware verification owns installation, Mac input consumption, and audible acceptance.

The approved explicit Mac-input route is BlackHole2ch. Discovery and runtime validation share `HALMicrophoneDeviceRegistry`. They translate the bundle ID with `kAudioHardwarePropertyTranslateBundleIDToPlugIn`, verify the returned plugin's bundle ID, and require the exact device in `kAudioPlugInPropertyDeviceList`. `kAudioObjectPropertyOwner` is not a plugin lookup; the observed device's owner is the system object. UID resolution, virtual transport, alive state, 48 kHz, both two-channel streams, channel mapping, paired TLS fingerprint, peer, and video/input generations remain checked. Route activation still refuses an already selected or running target and conditionally restores only its own default-input selection.

Two designs were compared before implementation.

| Candidate | Decision |
| --- | --- |
| Keep generic catalogs and add client exceptions for omitted capability | Rejected because absence would mean both revocation and an ordinary update; identity validation would remain duplicated. |
| Share plugin membership checks and publish one catalog per peer | Selected because discovery/runtime use the same rule and each connection retains its own capability and replay catalog. |

The microphone policy now resolves permission after the user's explicit toggle and before asking the Mac to allocate input. Permission does not open an engine. A request ID, scope, and connection fence every permission completion; cancellation, backgrounding, or a connection/source change discards the completion. A temporary inactive phase caused by the permission prompt preserves that pending consent. An actual interruption cancels it. Capture still requires the exact active host grant and the exclusive audio lease, which rejects overlap with canvas dictation. Normal local interruption/background stops keep the unchanged Mac scope and process the stop acknowledgement, allowing a later explicit toggle without waiting for an unrelated window change. Source/peer changes continue to revoke the scope.

Every ordinary window update carries one peer-specific microphone catalog. A preparing or active owner's capability remains stable; retiring and failed cleanup advertise none, including during an explicit retry. Catalog replay is cached per client. Hello replay rechecks the retained grant, fingerprint, and committed video epoch at the send boundary; it strips a revoked or reset capability. One client's capability is never replayed to another. A new video epoch can still revoke the old capability through the normal video-commit catalog.

Failed host cleanup retains the same sink with rendering closed and hides microphone capability. The Mac CCR Sill General settings expose an explicit cleanup retry using that retained lease ID. A retry clears the action while in progress, updates the local status, and republishes per-peer catalogs only after its result. Recovery does not start capture or allocate another sink; a fresh iPad toggle is required. The iPad keeps host cleanup guidance independently of capability availability, so the failure response followed by a nil-capability catalog retains the Mac recovery instruction. A fresh capability clears that instruction without starting capture. Reconnecting cannot bypass cleanup. The wire schema, TLS, and pairing remain byte-for-byte unchanged. This replaces the initially proposed cleanup wire ticket at the parent's frozen-protocol integration constraint.

Regression verification uses inert CoreAudio object/unit seams and exact extracted coordinator/server methods. FakeHAL reproduces system owner 1, plugin 34, and device 96. The Mini runner uses a uniquely owned volatile RAM input, single heavy-job admission, hash checks, bounded children, and volume cleanup. These are independent input checks, not `codex-source-guard` task-transfer acceptance, independent review, an installed build, or physical audio proof. Check receipts for the exact candidate and completed gates; historical results above do not apply to this patch.

The final `ipad-mic-plugin-07` independent Mini input passed 387 host assertions, all 20 compiled fault variants, 101 audio-routing assertions, and five iPad policy/gate/lease/cleanup/route-adapter suites. Sender/receiver input hashes matched, included sources stayed unchanged, children were reaped, and RAM input/output were removed. No whole Mac target build ran in this final attempt. The parent separately reports native read-only registry validation of device 96, `BlackHole2ch_UID`, plugin `audio.existential.BlackHole2ch`, both two-channel streams and 48 kHz using source SHA `e047409daa9c072a78ddefa5977d27c3f8c67fefadd57bf760f5f4c26a2a2092`; no audio unit or route change was part of that proof. Final exact-commit independent review, iOS/Mac SDK signing, installation, and live audio acceptance remain parent gates.
