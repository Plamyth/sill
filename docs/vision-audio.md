# Native received audio

Work key `vision-received-audio-20261016`. Owner01a13005-ff61-7780-b0e8-6dc171de1c9d. Base8ef216d121ac3e98fb3c098814c10b7d6cc2dd1b, branch codex/vision-sill-audio-20261016. iPad owner01a13ace-e372-7ed1-9946-149df37ee1c3 owns common wire and host capture. This unit adds explicit native received-audio consent and playback. Microphone, voice commands, and the original call remain separate required work.

## Checklist

- [x] Ground. Trace MessageReader, StreamClient deliver, SessionLink handover, native scene and input transition lifetime, pinned peer player89f9550.
- [x] Sketch. Compare a view-owned binding/controller with a client-owned connection-scoped controller.
- [x] Agree. Proceed under the user's autonomous development instruction. Common wire ownership remains with the iPad owner.
- [ ] Implement. Consent, revocation, bounded player, native control, scoped wire adapter after the common contract is clean.
- [ ] Scrap. Revisit the architecture if source attribution or subscription ordering cannot be proved. Do not relabel old packets with current UI source.
- [ ] Focused Mini RAM checks, exact native build, independent review, existing Page update. No installation or audio I/O.

Throughput checkpoint. Parent writes policy/controller/native UI/client hooks/project list in this worktree. One playback worker writes only its player/buffer/test/doc files in its separate worktree from the same base. Pure checks run in one Mini heavy RAM stream with source and cleanup receipts. XROS compilation stays on MacBook because Mini has no XROS SDK, after a compiler lease exchange. Each path has its first attempt and at most two diagnostic corrections. No new remote checkout or repeated device/auth probing.

## Problem and current flow

The native workspace owns one client. The network queue admits messages only from its current NWConnection. SessionLink can change the connection while `connected` stays true, and can retain ordinary sends during a handover. A queued unscoped Enable must never reach a replacement peer. Source changes and revocation must invalidate asynchronous decode and rendering, not only a SwiftUI Boolean. WindowGroup permits more than one workspace while AVAudioSession belongs to the process.

Peer89f9550 supplies AudioPacket and an AAC decoder/player. Its packet format has no source generation. Its receive method can restart after stop, and dispatches one decode closure for every packet. Those are source observations, not installed-app defects. The shared host must fence old capture/codec/output generations before acknowledging a new request. The native client cannot infer packet origin from the current window title.

## Usage

The native control observes `client.visionAudio`. Explicit Enable calls `enable()`. Stop calls `stop()` from a sibling of the disabled pointer/input controls. At the start of any source or disconnect transition, on inactivity/disappearance, and on connection replacement, consent is revoked before any input fence wait. Foreground and reconnection do not re-enable it. Unsupported hosts show a reason and cannot subscribe.

The transport supplies a stable connection identity plus a source generation and acknowledged capability. Native policy receives a context, sends one fresh request only on explicit Enable, and admits packets only after the matching request is acknowledged. Packet receipt cannot grant consent. Rendering means valid PCM was consumed by the render callback, not that the engine started or a physical speaker was heard.

## Shape and synthesis decision

Candidate A was independently grounded by Gauss. A view owns a controller and detachable transport binding. It aligns UI lifetime with consent but makes callers coordinate binding, capability, source, teardown, and connection handover across multiple owners.

Candidate B is the parent proposal. StreamClient owns one controller for its authenticated connection lifetime. The view observes and asks it to Enable/Stop. A single typed VisionAudioState owns consent. The player owns a process-wide playback lease and bounded ingress/render storage. The client adapts exact connection/source identity and sends audio control directly to the captured peer, with a scope check at actual send, rather than retaining it in SessionLink's cross-peer queue.

B is selected for fewer binding states and explicit handover revocation. A's requirements are retained: Stop outside input disabling, immediate render invalidation, one scheduled decoder drain, source/request identities, error/route/interruption revocation, and no automatic resume. Model the Domain makes requesting, waiting, rendering and failure exclusive states. Component and common-wire changes are reviewed independently; a clean native build does not prove the host fence.

## Contract and open gates

The iPad owner delivered clean d962c0901ad0b3345172721f4dba6934476ee5cf with WindowList.remoteAudio=1, kind200 request UUID and kind201 echoed UUID or nil revocation. Parent requested correlation and a host generation/output fence before acceptance. Four common components were copied from exact Git blobs with SHA-256, leaving peer dirty work alone. Peer ordinary capture returned remote_ref_unknown because its branch is not published. These are separate candidate components, not accepted same-task transfer. The peer200 protocol checks and macOS build are owner reports and do not validate this native candidate. Independent contract review remains required before safe source attribution is accepted.

The received-audio engine uses mixWithOthers without ducking, microphone, route override, global device changes, or Full Space. A disabled/unbound controller never activates a session. Session deactivation belongs only to the player that acquired its process lease. A stop invalidates queued packets, decode completion, restart and render output synchronously; cleanup follows. The initial buffer values are policy choices, not measured latency or movie coexistence.

Physical source identity, Vision output, movie coexistence, interruptions, actual remote network and same-call microphone are unaccepted. The original E1–E4 criteria stay unchanged.

## First consent evidence

The actual VisionAudioState source ran in one Mini RAM stream with synthetic connection/source context.35/35 checks passed, including unmatched/old request UUID, pre-ACK rejection, source A→B→A, replacement peer, foreground no-resume, host refusal and bounded no-response/sample waits. Sender/receiver hashes match, sources unchanged, childPIDs19415/19504 reaped, RAM input and isolated output removed. Swap9838.19MB was unchanged and Orca process identities matched. This tests the pure policy, not the native view, engine, transport, notification delivery or host fence.

Current implementation reconciliation. Native StreamClient owns the controller. A new private handler parameter carries the actual originating connection through asynchronous lists/settings/Mac info/goodbye/menu delivery; replayed move messages go through deliver with their origin. Direct connection setter, successful handover, teardown, source request, scene inactivity and transition request revoke audio. Positive subscription commands capture the exact route and recheck current connection/scope/grant at queue execution; they bypass SessionLink retention. False cleanup stays on its captured old connection. The native Stop is outside the disabled input subtree. Category-change notifications caused by setting our own audio category are ignored; route/device changes, media reset and interruptions revoke without auto-resume. Physical notification and movie coexistence acceptance remains open.

An independent contract reviewer spawn was rejected by the shared agent capacity limit while the playback writer is active. No verdict was inferred. The next review will use the freed writer slot after clean delivery and explicit closure. No repeated spawn under the same capacity condition.

## Shared host review

Hume independently reviewed exact d962c090 against cb9c743 and returned NOT CLEAR. Two P1 findings and one P2 were sent to the original iPad owner. No installed host was changed.

1. A pending ON awaiting a previous asynchronous stop can resume after a later OFF ACK, start capture before validating its request, then reject the request without stopping that newly started capture.
2. didStopWithError clears the stream reference, while stop returns early on nil without draining/resetting the PCM packer. A partial old packet can complete under a newly installed callback/epoch.
3. With a second subscriber keeping capture alive, old captured samples delayed before emission can reach a newly re-enabled client after its ACK because admission uses only current subscription Boolean. Network queue ordering does not fence the upstream sample boundary.

Host fence acceptance is open. The native candidate will not treat a matching request UUID alone as proof of fresh source audio. The original owner must supply corrected commits and relevant isolated evidence, followed by narrow independent closure. Native pure-policy/buffer tests do not close these findings. The read-only reviewer was explicitly closed after delivery.

The actual controller and route methods passed29/29 Mini checks with a fake player and identity-only peer. Controller code compiled unchanged except AVAudioSession observers remain visionOS-only; route imports are removed and fixture types replace Network/StreamProtocol identities. The source and emitted hashes are separately recorded. Checks cover zero default-off side effects, matching ACK, stale source/packet/render rejection, explicit stop/error, no foreground auto-resume, same-peer false cleanup, and a concurrent send/Stop fence. The positive send body stays under the consent lock, so a revoked queued Enable cannot execute after Stop. No AVAudioEngine/Session or network connection was constructed. RAM/outputs and transport/children are reaped. Native compilation and notification/runtime behavior remain open.
