# 순정 Codex 원격 음성의 기존 IPC 확장

2026-11-05. Root Host와 Core가 구현할 계약 초안이다. 현재 설치본에서
지원한다고 광고하지 않는다. Host243의 기존 duplex 복구와 별도로 진행한다.

기존 `CodexControlRoom/command.sock`의 0600 권한, 경로·프로세스 검증과
provider 제어 흐름을 재사용한다. 새 HTTP endpoint나 client message kind,
녹음기를 추가하지 않는다. Core callback을 재생하는 기존 가상 출력 함수는
없으며 Host 캡처는 자체 프로세스 오디오를 제외하므로, 가상 출력 경유를
구현 완료로 간주하지 않는다.

## 소유권과 현재 상태

- Core: 독점 app-server 연결, 현재 대화의 prepared target, producer,
  attach 승인, callback의 동기 복사와 입력 append.
- Root Host: Sill connection, subscriber, epoch와 현재 media lease의 결속,
  PCM 변환, 순서 검증, 기존 kind33 전송.
- Root Node: 기존 Android relay의 raw48k 입출력 슬롯과 private control 경계.
- 기기: 기존 입출력만 사용한다. iPad·Vision의 AudioPacket 수신과 Android의
  48k mono uplink/48k stereo downlink 계약은 유지한다.

이 문서는 구현·설치·실제 통화 수용을 대신하지 않는다. attach와 framing의
최종 공통 필드는 Core와 대조한 뒤 같은 버전으로 고정한다.

## Attach

첫 요청은 기존 16KiB 한도의 한 줄 JSON이다.

```text
schemaVersion: 1
op: provider.media.attach
coreGeneration: 현재 Core UUID
target: 기존 prepared target의 원문 6필드
media: {pairedDeviceId, transportKind, clientConnectionId, intentGeneration,
        bindingEpoch, transportId, leaseRevision, audioEpoch}
```

`target`은 기존 6필드 및 hash를 그대로 사용한다. thread와 voice UUID의
원문 대소문자도 보존한다. `media`는 임의 권한 발행 값이 아니라, 이미
승인된 동일 기기·현재 forwarding binding의 readback이다. `transportKind`는
`native` 또는 기존 `http` 값이며, revision과 epoch는 원래 UInt64의 십진 문자열이다.

Core는 실제 승인·시작된 같은 통화, 현재 producer connection과 media scope를
확인해야 한다. 검증하지 못하면 attach를 거절한다. Host는 현재 연결·구독·
로컬 음소거 보호·Node authority identity를 별도로 계속 검사한다.

ACK 뒤 Host의 ready를 받기 전에는 binary frame을 보내지 않는다. 기존 제어
parser가 ACK와 binary 데이터를 한 JSON 응답으로 읽는 혼합을 금지한다.
active 통화에 속한 시작 직후 callback만 제한된 메모리 큐에 보존할 수 있다.
과거 통화·unbound callback이나 전사·PCM 로그는 보존하지 않는다.

기존 challenge와 public Result에는 producer connectionId가 없다. Host는 이를
만들지 않는다. Core가 target에 결속된 현재 producer를 찾아 ACK로 반환한다.
ACK의 정확한 필드는 `schemaVersion=1`, `op=provider.media.attached`,
`coreGeneration`, 원래 producer `binding`, 원래 `media`, 현재 `realtimeSessionId`다.
`binding`은 `{target, providerInstanceId, voiceSessionId, connectionId}`다.
Host의 ready는 같은 context를 가리키는 `kind=ready` binary header이며 PCM은 없다.

## Binary framing 초안

```text
UInt32 big endian bodyLength
UInt16 big endian jsonHeaderLength
UTF8 JSON header
PCM16LE bytes
```

header는 4096 bytes 이하, PCM은 프레임당 240 samples/480 bytes 이하이다.
24kHz 모노 10ms는 240 samples이며, 480 samples는 20ms다. 전체 길이와
정확한 샘플 수를 검증한 뒤에만 할당·소비한다. 중복 JSON 키, 추가 필드,
비정상 UTF8, 빈 PCM, 홀수 바이트, 다른 포맷, overflow는 거절한다.

출력 header의 정확한 필드는 다음과 같다. `media`는 attach와 같은 객체다.

```text
schemaVersion=1, kind=output, coreGeneration, targetHash, voiceSessionId,
connectionId, media,
realtimeSessionId, sourceSequence, eventSequence, chunkSequence,
chunkOffsetSamples, chunkSamplesTotal,
format={encoding:pcm_s16le,sampleRate:24000,numChannels:1},
samplesPerChannel, itemId
```

sourceSequence는 SDK wire의 원래 필드가 아니라 기존 Core ingress envelope의
순번이다. eventSequence와 chunkSequence도 producer가 만든 원래 값을 보존한다.
하나의 callback을 나눌 때 chunkSequence를 재발급하지 않고 offset과 total을
사용한다. 원본 chunk는 최대 10초다. Host는 누락·중복·역순을 거절한다.
입력은 같은 attach scope에서 별도 연속 inputSequence를 사용하며 실제 기존
마이크 수신과 현재 lease가 검증된 프레임만 변환해 append한다.

순번은 `1`부터 JavaScript safe integer 최대값까지의 canonical 십진 문자열이다.
원본 chunk 내부 offset은 0부터 연속하며 total과 실제 PCM 길이가 일치해야 한다.
입력 header는 같은 context와 `kind=input`, `inputSequence`, `format`,
`samplesPerChannel`, `itemId`를 갖고 출력의 원본 notification 순번을 만들지 않는다.
ready와 종료 제어 header는 PCM을 운반하지 않는다. media EOF는 통화 종료의
확인이 아니며, 기존 ProviderCallResult의 실제 stopped 확인을 별도로 유지한다.

## 출력 경계와 종료

SCK sampleSequence와 native chunkSequence는 다른 순번 공간이다.
`broadcastRemoteAudio`의 capture boundary에 native 순번을 대입하지 않는다.
Host는 현재 native subscriber·lease·epoch에 결속한 별도 전달 경계를 둔다.
필요한 Host 로컬 전송 카운터는 원본 순번으로 표시하지 않는다.

전송은 10ms 단위로 처리하고 유한 큐와 backpressure를 적용한다. callback은
반환 직후 PCM이 소거되므로 소비자는 반환 전에 bounded copy를 끝낸다.
큐 상한 초과·gap·현재 scope 상실·Core/Host/Node 재시작·EOF에서 해당 native
세션을 닫고 잔여 PCM을 소거한다. 재전송·자동 새 통화를 만들지 않는다.

native transport는 기존 Sill kind33을 사용한다. Android relay에는 24k PCM을
raw48k 슬롯에 넣지 않고 Mac 변환 경계에서 기존 48k 형식으로 돌려 보낸다.
각 경계의 Source/SDK/통합/설치/실제 start-input-output-stop 결과는 분리한다.

Node http 경계는 기존 private control의 읽기 전용 `forwardingRelayPCMInspect`로
현재 active session만 확인한다. Core ACK를 받은 뒤 `forwardingRelayPCMAttach`로
같은 session과 producerConnectionId를 결속한다. Inspect와 attach 사이에 scope가
바뀌면 거절하며 최근 종료 metrics나 다른 session을 대신 사용하지 않는다.
기존 inspectRuntime 응답과 public HTTP 계약은 바꾸지 않는다.
