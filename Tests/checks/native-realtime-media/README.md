# Native media codec의 Root 호출 계약

이 fixture는 동일 Mac 순정 Codex 통화의 원격 입력과 출력을 위한 독립 소스 단위를 검증한다.
실제 IPC, Host, UI, 기기, 오디오 장치, registry와 Root 원장은 조작하지 않는다.
원음과 전사는 저장하지 않는다. PCM은 코드에서 만든 합성 값만 사용한다.

## API

```swift
let attach = try NativeRealtimeMediaScope.decodeAttach(attachJSON)
let scope = try NativeRealtimeMediaScope.acceptAcknowledgement(ackJSON, for: attach)
let decoder = NativeRealtimeMediaDecoder()
let packetizer = NativeRealtimeMediaPacketizer()
try decoder.activate(scope: scope)
try packetizer.activate(scope: scope)
let ready = try NativeRealtimeMediaCodec.ready(scope: scope)

do {
    try decoder.feed(bytes) { borrowed in
        switch borrowed.header.payload {
        case .output:
            try packetizer.offer(borrowed)
        case .input, .ready:
            break
        }
    }
    if let packet = try packetizer.pull() {
        // Root가 현재 auth/subscriber/lease를 다시 검증하고 해당 transport로 전달한다.
        // packet.audioPacket의 수명과 전송 후 소거도 Root가 소유한다.
    }
} catch {
    decoder.retire(.scopeLost)
    packetizer.retire(.scopeLost)
    throw error
}
```

Root는 인증된 기존 경로에서 attach와 ACK를 분리해 읽는다.
attach는 `schemaVersion/op/coreGeneration/target/media`만 가진다.
ACK는 `schemaVersion/op/coreGeneration/binding/media/realtimeSessionId`만 가진다.
`binding`은 기존 target6와 providerInstanceId, voiceSessionId, connectionId다.
scope는 원문 target, provider와 voice의 일치를 확인한 뒤 ACK의 connectionId를 고정한다.
scope 자체는 권한, 승인 또는 capability를 발급하지 않는다.

`feed(Data, consume:)`와 `feed(UnsafeRawBufferPointer, consume:)`는 동기다.
`NativeRealtimeMediaFrame.pcm`은 callback 반환까지 빌린 포인터다.
callback 밖에서 사용할 소비자는 반환 전에 유한 복사를 마친다.
`offer`는 최대 480B를 내부 ring으로 복사하고 포인터를 보존하지 않는다.
포인터를 보관한 뒤 읽는 호출은 지원하지 않는다.

`pull()`은 정확히 240 samples의 기존 `AudioPacket.pack` 결과 또는 nil을 반환한다.
반환한 packet은 Root 소유다. codec은 이미 넘긴 Data를 나중에 소거할 수 없다.
`Packet.segments`는 원본 sourceSequence, eventSequence, chunkSequence, total과 itemId를 보존한다.
각 segment의 `chunkOffsetSamples`와 `samples`는 해당 packet이 소비한 원본 범위다.
한 packet은 최대 240개의 segment를 가진다.
`nativePacketSequence`는 Host 로컬 1부터 시작하는 별도 domain이다.
SCK capture sampleSequence와 원본 notification 순번을 대신하지 않는다.
sourceSequence는 Core ingress envelope의 순번이며 SDK wire 필드가 아니다.

입력은 `NativeRealtimeMediaCodec.input(scope:sequence:itemId:pcm:)`으로 만든다.
PCM은 이미 Root가 24kHz mono PCM16LE로 변환한 1...240 samples다.
반환 Data의 전송과 소거는 Root가 소유한다.
decode된 input은 1부터 연속한 inputSequence를 요구한다.
encoder의 순번 진행과 실제 입력 lease 검증은 Root 책임이다.

## 수명과 한도

각 인스턴스는 inactive에서 한 번 activate하여 current가 된다.
실패, EOF 또는 scope 상실 뒤에는 retired이고 재활성화할 수 없다.
scope 변경 시 Root가 두 객체를 폐기하고 새 객체를 만든다.
이전 객체에는 PCM, 부분 packet과 모든 순번 경계가 남지 않는다.
foreign frame이나 늦은 callback은 scope를 활성화하거나 교체할 수 없다.
decoder 실패 뒤에는 Root가 packetizer도 폐기한다.
동기 callback에서 decoder 재진입은 두 번째 호출을 거절하고 현재 decoder를 폐기한다.

decoder의 고정 scratch는 prefix를 포함한 4582B다.
body는 최대 4578B, UTF8 JSON header는 최대 4096B, PCM은 최대 480B다.
기존 `LocalAudioRelayJSON.validate`로 중복 키와 UTF8을 검사한다.
외부 JSON의 모든 객체는 정확한 키 집합과 형식을 검사한다.
첫 chunk는 임의의 양수 safe-integer 순번으로 시작하되 offset은 0이다.
같은 chunk는 source, event, item, total을 고정하고 offset을 연속시킨다.
다음 chunk는 이전 chunk 완료 후 chunk+1, offset0이며 source와 event는 증가한다.
source와 event는 중간 transcript 등의 ingress를 고려하여 정확히 +1을 요구하지 않는다.

packetizer PCM ring은 480000B다.
원본 callback 한도는 240000 samples다.
pending frame 메타데이터는 최대 2000개다.
작은 조각이 많으면 PCM 한도보다 메타데이터 한도에 먼저 도달할 수 있다.
한도를 넘거나 순번 검증이 실패하면 owned PCM을 `memset_s`로 소거하고 retired가 된다.
내부 Task, Timer와 callback queue는 없다.

EOF는 `finish()`로 잘린 frame과 미완 chunk를 검사한 뒤 decoder를 폐기한다.
Root는 packetizer도 `.endOfStream`으로 폐기한다.
이 로컬 control은 실제 통화 stopped 확인을 만들지 않는다.
실제 stop은 기존 ProviderCallResult에서 별도로 확인한다.

## 미확정 계약과 적용 한계

2026-11-05에 Root integration WT의 갱신 draft를 읽었다.
draft SHA256은 `53312bd1c4f756a9743077d916423cde08180069d29fd2a4e87e93a18b49ca7c`다.
문서의 media는 8필드다. 최초 요청의 media9에 해당하는 추가 필드는 정의되지 않았다.
codec은 확인된 8필드만 허용하고 알려지지 않은 authority 필드는 거절한다.
wire 종료 control의 kind와 정확한 필드도 정의되지 않았다.
이 codec은 ready, input, output만 decode하고 임의의 control header는 거절한다.
Root와 Core의 최종 ACK 대조가 필요하다.

transportKind는 기존 `http` 또는 `native`다. `relay` 값은 없다.
clientConnectionId는 Root가 공급한 실제 현재 Native Sill connection 또는 HTTP session UUID다.
Android HTTP 슬롯은 입력 48k mono와 출력 48k stereo다.
이 codec의 24k AudioPacket을 그 raw 슬롯에 직접 쓰지 않는다.
Root의 별도 변환 경계와 실제 current subscriber/lease 검증이 필요하다.

## 실행과 근거

`python3 -B Tests/checks/native-realtime-media/run-mini.py`가 필요한 소스만 Mini 임시 경로에서 실행한다.
runner는 기존 target/hash와 JSON 검증 코드를 원문에서 추출하고 실제 StreamProtocol을 빌드한다.
새 소스와 fixture를 Mac SDK에서 warnings-as-errors로 typecheck한다.
합성 codec 모델, 기존 provider-call-bridge와 NativeRealtimePCM 회귀를 실행한다.
전후 SHA와 Mini 삭제 영수증은 이 fixture의 `validation-NN.json`에 남는다.
`--sdk-only`는 같은 단위 typecheck만 현재 Mac에서 실행한다.
Mini 입력과 빌드 출력은 종료 후 삭제한다.
이는 전체 Host SDK 통합과 codex-source-guard 작업 이전 수용 증거가 아니다.

Pstack 0.9.130 Feature를 적용했다.
how는 실제 source 경계의 단일 순차 분석으로 수행했다.
Model the Domain은 scope, header payload와 inactive/current/retired 상태로 구현했다.
Boundary Discipline은 외부 JSON과 framing 진입에서 검증하고 내부 typed 값을 사용하도록 적용했다.
Ponytail은 기존 JSON 검사와 AudioPacket을 재사용하고 새 의존성과 런타임을 추가하지 않는 선택에 적용했다.
사용자 지시에 따라 ARENA, 경쟁 설계와 별도 fanout은 실행하지 않았다.
독립 reviewer는 실행하지 않았다. `BLOCKED: independent review`이며 merge-ready와 shipping은 닫혀 있다.
actualHost241/OFF와 pending243의 교체, 공식 integration ref, 설치와 기기 수용은 이 작업 범위 밖이다.
최종 SDK 통합, 실제 Core 연결과 오디오 수용은 false다.

검증 결과는 `verification.json`에 기록했다.
합성 codec 1655개, provider 요청 16개, typed target/result 183개와 PCM 95개 검사를 통과했다.
40개 입력 파일의 맥북·Mini 전후 SHA가 일치했다.
양쪽 Mac SDK 단위 typecheck와 임시 경로 삭제를 확인했다.
