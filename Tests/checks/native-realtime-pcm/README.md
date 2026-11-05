# 순정 realtime 메모리 PCM codec 작업 원장

2026-11-05. 원담당 하위작업 `01a1ab5f-635e-7501-856d-97caeac51d92`.
기준 `f46c6c4a012e53346b54d01fd764681aacc30b3d`, tree `bea73fbb021c22615c9da42743ee404df4324bdd`.
브랜치 `codex/ipad-native-realtime-pcm-20261105`. 통합 책임자는 부모 iPad 담당이다.
소유 파일은 이 검사 폴더와 `iOSClient/NativeRealtimePCMCodec.swift`뿐이다.
부모의 integration, 기존 소스 파일, DerivedData, 기기, Host, UI, 권한은 쓰지 않는다.

## 재사용한 근거와 최소 설계

Core 원담당 후보 `884d69d61d5540a6f82277db65afbc96ed1f0b7b`의
`bridge/native-realtime-producer.protocol.md`, `bridge/native-realtime-producer.js`,
`tests/native-realtime-producer.test.js`를 실제 읽었다.
Core는 입력 최대 48,000 bytes, 출력 최대 480,000 bytes를 검사한다.
audio DTO 필드는 `data`, `sampleRate`, `numChannels`, `samplesPerChannel`, `itemId` 다섯 개다.
샘플 수와 item ID는 null을 허용한다. null 필드도 인코딩에 포함해야 한다.

기준 소스에는 `MicrophonePCMEncoder`라는 타입이 없다.
`IPadMicrophoneConversionWorker`가 AVAudioConverter 입력 분할과 세대 검사를 수행한다.
출력은 48kHz Float32이며 `IPadMicrophonePCM`의 고정 960프레임 패킷화와 결합돼 있다.
기존 `Tests/checks/ipad-microphone-pcm/conversion.swift`는 44.1kHz stereo 변환과 stale capture를 검사한다.
기존 타입을 24kHz로 설정하거나 flush할 API가 없고 파일 소유권도 부모에게 있으므로 수정하지 않는다.
새 codec은 같은 AVAudioConverter 입력 블록 방식을 사용하되 48kHz mono PCM16LE 메모리만 받는다.
일반 resampler, 새 queue, provider, 수집 세션은 만들지 않는다.

데이터 형태는 `NativeRealtimeAudio`와 직렬 소유 codec 하나다.
`active → finished/failed`, `reset → 새 local generation`으로 수명을 제한한다.
owner는 처리 시작 때 `let generation = codec.generation`을 보존하고
`codec.append(pcm, frameCount: 960, generation: generation)`을 호출한다.
이전 callback이 현재 generation을 다시 읽어 자기 것으로 바꾸면 안 된다.
반환 배열이 비어 있으면 converter가 아직 출력하지 않은 것이며 가짜 무음을 만들지 않는다.
각 반환 DTO를 즉시 소비하고 owner가 전송 backpressure를 적용한다.
`flush`는 converter의 메모리 tail을 내보내고 종료한다. 두 번째 flush는 빈 배열이다.
`reset`은 이전 tail을 버리고 새 세대를 발급한다. 이전 세대 append와 flush는 거절한다.
generation은 로컬 reset 경계일 뿐 Core binding이나 Host 권한의 증거가 아니다.
이 클래스는 Sendable이 아니며 같은 직렬 owner가 callback 밖에서 호출한다.

[공식 0.164.0 DTO](https://github.com/openai/codex/blob/6aaac694803004a63c6f393d153c96d22521a6b9/codex-rs/app-server-protocol/src/protocol/v2/realtime.rs)와
[Apple TN3136](https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions)을 대조했다.
변환은 sample-rate 변환을 지원하는 입력 블록 API를 사용한다.
메모리 버퍼와 base64 문자열의 강제 소거를 보장하지 않는다. codec은 PCM 대기열·파일·로그를 만들지 않는다.

## Pstack 실행 체크리스트

- [x] `how` over the affected subsystem. 위 근거와 변환 흐름을 직접 대조했다. spawn 도구가 없어 단일 조사로 수행했다.
- [x] `architect` for parallel design exploration. 사용자 ARENA 금지가 우선하므로 후보 경쟁은 수행하지 않았다. 위 최소 타입으로 직접 구현했다.
- [x] Blocking first steps. 기준 commit/tree, clean 상태, Core 후보와 파일 소유권을 확인했다.
- [x] Independent workstreams. 부모 SDK/실기 작업과 이 codec 구현은 별도 워크트리로 병렬이다.
- [x] Shared mutable state. integration, capture 파일, DerivedData, 기기, Host에 쓰지 않는다.
- [x] Smallest safe decomposition. codec과 계약 검사가 한 묶음이므로 단일 writer다. 중복 resampler는 만들지 않는다.
- [x] Delegate code-writing to a subagent. 이 작업 자체가 부모가 위임한 독립 하위작업이며 중첩 spawn 도구는 없다. 상속모델로 직접 구현한다.
- [x] Verify on the matching surface. Mini의 실제 macOS AVAudioConverter와 Core 격리 producer로 아래 검사를 통과했다.
- [x] Rebase into small, ordered commits. 지정 기준에서 추가 파일만 단일 검토 후보 커밋으로 반환한다. integration은 변경하지 않는다.
- [x] If the design is contested, `interrogate` before shipping. 해당 없음. 계약과 범위가 지정됐다.
- [x] Run **Opening a PR**. skip: 부모가 통합을 소유하며 이 하위작업은 commit 반환만 요청받았다.
- [ ] BLOCKED: independent review. 이 런타임에는 spawn 도구가 없다. 부모의 별도 독립 검수 전 merge-ready로 표시하지 않는다.

Ponytail은 플랫폼 AVAudioConverter와 Foundation을 사용하고 기존 파일 수정·일반 추상화·새 의존성을 생략하는 데 적용했다.
Model the Domain은 단일 phase와 local generation으로 reset 경계를 표현하는 데 적용했다.

## 검사와 실행 근거

`python3 Tests/checks/native-realtime-pcm/run.py OUTPUT_DIRECTORY [CORE_MODULE NODE_EXECUTABLE]`는 macOS의 실제 AVAudioConverter와 합성 메모리만 사용한다.
새 mic session/tap/AVAudioEngine/권한/API/네트워크/파일 원음을 사용하지 않는다.
합성 신호의 48k→24k 샘플 수, 20ms 분할 동등성, tone·DC·무음·anti-aliasing을 검사한다.
1,500개 연속 블록의 샘플 합계와 flush/reset/stale, DTO 경계를 검사한다.
이는 30초 분량의 합성 변환 검사이며 30초 실시간 실행·지연·청취 성능 검증은 아니다.

첫 Mini 실행은 `2026-11-05T11:06:49Z` 시작 후 SSH 종료 코드 255로 실패했다.
해당 실행의 `cleanup_verified=true`를 readback했다.
영수증 `/Users/ambrion/Library/Application Support/Mini Ephemeral Source/receipts/20261105T110650.810266Z-native-realtime-pcm.json`.
작업 전용 Mini 경로 `/Users/sin-wonho/.local/share/mini-ephemeral-source/runs/01a1ab5f-635e-7501-856d-97caeac51d92/native-realtime-pcm`.

최초 변환 검사에서는 `.none` priming이 48,000 input에서 24,000 output과 flush tail 16샘플을 반환했다.
별도 probe에서 48,000, 960, 1프레임 분할 모두 같은 결과임을 확인했다.
`.normal` priming으로 바꾸고 flush를 포함한 정확한 24,000샘플과 분할 동등성을 재검증했다.
이어진 실패는 Node의 잘못된 추정 경로였고, 기존 `/Users/sin-wonho/.local/bin/node`를 관측한 뒤 명시적으로 전달했다.
두 장애는 다른 원인이며 같은 조건의 무변경 반복은 하지 않았다.

최종 실행은 `2026-11-05T11:13:49.518608Z`부터 `11:14:30.459621Z`까지다.
Mini Swift 6.3.3, `arm64-apple-macosx26.0`, Swift 언어 모드 5를 사용했다.
명령은 `mini-ephemeral-source run --source EXECUTION_INPUT --owner 01a1ab5f-635e-7501-856d-97caeac51d92 --job native-realtime-pcm -- python3 Tests/checks/native-realtime-pcm/run.py .scratch/native-realtime-pcm core/bridge/native-realtime-producer.js /Users/sin-wonho/.local/bin/node`다.
`EXECUTION_INPUT`은 storage-route가 정한 `/Volumes/BT-Workspace/Development-Archives/ccr-ipad/native-realtime-pcm-20261105/execution-input`이다.
Core 소스는 지정 커밋의 Git blob과 대조한 격리 입력이며 원담당 워크트리에는 쓰지 않았다.

최종 결과는 네 묶음 모두 PASS다.

- DTO 다섯 필드, 명시적 null, canonical base64, PCM 길이·샘플 수·식별자, 입력 1초·출력 10초 경계.
- 1kHz tone, DC 양·음 극성과 Int16 한계, 무음, 18kHz anti-aliasing, 1초·20ms·1프레임 분할의 샘플 수와 출력 동등성.
- 1,500개 연속 960프레임 입력에서 720,000 출력 샘플, flush 두 번, 빈 flush, reset 후 무음, 이전 세대 append/flush 차단.
- Swift 출력 DTO와 1초 입력·signed16LE sentinel을 실제 Core producer 후보에 메모리 pipe로 전달하고, append 수용 및 null sample-count 출력 callback의 바이트 일치를 확인했다. RPC는 메모리 stub이며 실제 app-server나 provider 연결은 없다.

최종 영수증은 `/Users/ambrion/Library/Application Support/Mini Ephemeral Source/receipts/20261105T111430.461740Z-native-realtime-pcm.json`이다.
`status=completed`, `exit_code=0`, `cleanup_verified=true`이며 위 Mini 실행 경로의 부재를 확인했다.
원격이 읽은 codec SHA256은 `a39e310cd750c5c3a02708a3f9c7e14aa42f004481d5334e84a3df25146db47e`다.
Core JS SHA256은 `b45bcfa45031c087ceea529cfedbb26eed9bbec1f77ed42f669f7a79eaf34b38`다.
검사 runner는 수신한 codec·검사·Core 파일 해시를 출력하며 최종 인계에서 맥북 파일과 다시 대조한다.
이는 격리 파일 입력의 좁은 검증이다. Git checkout을 요구하는 codex-source-guard verify 통과나 원담당 통합·설치 수용으로 표시하지 않는다.

## 연결 가능성과 남은 경계

입력 DTO는 Core `appendAudio`의 audio 경계와 같은 형태이며 별도 encoding·Host envelope 필드를 추가하지 않는다.
실제 Core binding, 연속 sequence, 전용 연결, `isCurrent`, 한 건씩 await하는 전송은 원담당 통합 범위다.
제품 mic callback에는 연결하지 않았다.

기존 `RemoteAudioPlayer.receive`는 DTO나 raw base64를 받지 않는다.
`AudioPacket.unpack`으로 얻은 PCM16을 `Float(sample)/32768`로 바꾸는 경로를 갖고,
`AudioPacket`은 24kHz mono를 수용하므로 형식상 연결 가능하다.
그러나 packet은 기존 Sill kind-33이고 Core는 app-server DTO다.
최종 Host envelope, admission과 세션 결속, packet 분할과 sequence는 미확정이므로 구현하지 않는다.
특히 player는 backlog가 150ms를 넘으면 최근 60ms만 보존한다.
따라서 최대 10초 Core 출력을 한 packet으로 직접 넘기면 전체 청취를 보장하지 못한다.
최종 owner가 bounded streaming·재생 정책을 확정해야 하며 이 codec은 player를 변경하지 않는다.

SDK 앱 빌드, 서명, 설치, 실제 입력·출력, Host/네트워크, 실기 청취와 수용은 미검증이다.
이 작업은 테스트 서버 변경 대상이 아니며 부모의 runtime/설치 후보에 자동 포함되지 않는다.

## 현장 효과 판정과 인계

원담당과 통합 책임은 부모 iPad 담당에게 유지한다. 이 하위작업은 지정 기준에서 다섯 추가 파일만 소유한다.
기준 integration은 clean으로 관측했으며 기존 RMS 수정이 포함된 capture 파일을 그대로 보존했다.
요구사항과 원본 계약은 위 Core 후보·Apple 문서·기존 변환기, 변경은 반환 commit/tree, 실행은 최종 Mini 영수증으로 연결한다.
클론 UI 대조와 실제 설치는 범위 밖이다. 합성 PCM만 처리했으며 외부 효과는 0이다.
제품 UI, 파일 원음, 로그 PCM, 인증·페어링·권한·라우팅·프로토콜, Host와 기기를 변경하지 않았다.
현재 단계는 구현·자동검사 통과 및 부모 검수용 commit 반환이다. SDK·서명·설치·실기 수용은 미검증이다.
다음 행동은 부모의 독립 검수와 별도 통합 판단이다. final Host envelope와 network bridge는 이 작업의 미완 구현으로 취급하지 않는다.
Mini 사본은 반환됐고 공유 기기·Host·오디오 lease는 획득하지 않았다.
오프라인 활성 소스는 분리 워크트리에 유지하고 외장 실행 입력의 중복 사본은 해시 대조 후 제거한다.
