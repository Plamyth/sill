# 연결별 영상 transport 회귀

기준은 `320da05b755a20ffacefc854fa6af3e55d944896`이다. `run.py`는 실제 `StreamServer.swift`의 Client 상태와 생산 메서드 본문을 추출한다. 실제 StreamMessage·PresentationMedia·WindowList·VideoEpoch 직렬화 코드를 함께 사용한다. NWConnection의 송신과 completion, PointerWatch의 물리 관측, grant 유효성 및 주변 링크 보고만 대역으로 바꾼다. listener·실기기·OS 입력·오디오 실행은 없다. private 접근 제한만 풀고 static과 메서드 본문은 보존한다.

## 최종 연결 서명

```swift
func enablePeerVideo(for connection: NWConnection) async -> Bool
func resetPeerVideo(for connection: NWConnection, expectedEpoch: UUID)
func preparePeerVideo(_ epoch: VideoEpoch, for connection: NWConnection,
                      admission: SourcePublicationAdmission)
func commitPeerVideo(_ epoch: VideoEpoch, catalog: StreamMessage,
                     admission: SourcePublicationAdmission, to connection: NWConnection,
                     requestKeyframe: @escaping () -> Void)
func sendPeerVideo(_ message: StreamMessage, epoch: UUID, to connection: NWConnection)
func sendPeerCatalog(_ message: StreamMessage, to connection: NWConnection,
                     admission: SourcePublicationAdmission)
func setPeerStreaming(_ on: Bool, for connection: NWConnection)
func setPeerPointerRect(_ rect: CGRect?, for connection: NWConnection)
var onPeerKeyframeNeeded: ((NWConnection) -> Void)?
```

부모 연결부는 enable의 true를 기다린 뒤 sendPeerCatalog를 사용한다. 기존 sendCatalog는 legacy lane만 배정한다. 새 선택·재시작마다 새 admission을 사용하고 이전 admission을 첫 await 전에 invalidate한다. reset에는 기존 준비 또는 실행 epoch ID를 전달한다. 기존 epoch가 없으면 reset할 영상도 없다. prepare/commit에는 동일한 admission 인스턴스를 전달한다. commit catalog의 active, inputGeneration, videoEpoch는 해당 epoch와 일치해야 한다. 초기·정지 catalog는 active.none/videoEpoch.nil이다. 준비 중 catalog 갱신은 보내지 않으며 commit이 영상보다 먼저 catalog를 전송한다.

prepare는 이전 pointer rect를 지우므로 commit 이후 setPeerPointerRect로 현재 bounds를 전달한다. rect 갱신도 부모의 현재 선택 ticket 검사 후 호출한다. onPeerKeyframeNeeded와 requestKeyframe은 network queue에서 호출되며 MainActor 상태를 직접 읽지 않는 callback을 설치한다.

PointerWatch.sample(devices:in:)는 부모 소유 변경에 의존한다. 이 transport 작업트리의 원래 PointerWatch에는 오버로드가 없어 단독 제품 빌드 대신 대역으로 검사했다. 부모가 해당 파일과 통합한 정확한 소스에서 실제 Mac SDK 빌드 및 독립 검수를 수행해야 한다.

## 실행

저장소 루트에서 생성한다. 생성본과 manifest는 이 폴더의 무시 파일이며 별도 소스 사본으로 커밋하지 않는다.

```sh
python3 -B Tests/checks/peer-video-transport/run.py --ref 320da05b --emit Tests/checks/peer-video-transport/Baseline.swift
python3 -B Tests/checks/peer-video-transport/run.py --emit Tests/checks/peer-video-transport/Current.swift
```

부모는 좁은 SDK 검사로 `/usr/bin/swift -swift-version 5 Current.swift`를 실행할 수 있다. Mini 실행에는 아래 승인된 한시적 실행 도구를 사용한다. 명시된 source는 현재 맥북 연결 SSD의 생성 입력이며 owner와 job을 유지한다.

```sh
/Users/ambrion/.local/bin/mini-ephemeral-source run \
  --source /Volumes/BT-Workspace/Development-Archives/CCR-Vision/peer-streams-20261022/transport-source/Tests/checks/peer-video-transport \
  --owner 01a1621c-6e0c-7a90-9836-f25deaf86905 \
  --job peer-video-transport-matrix \
  -- /bin/sh -c '/usr/bin/swift -swift-version 5 Baseline.swift; baseline=$?; /usr/bin/swift -swift-version 5 Current.swift; current=$?; test "$baseline" -eq 1 && test "$current" -eq 0'
```

baseline은 generic epoch media 우회, 다른 peer catalog 덮기, 다른 peer prepare의 reset, 오래된 무범위 reset의 새 epoch 중단을 재현하며 4건 모두 실패한다. 구현본은 29개 검사를 통과했다. `evidence.json`에 실제 입력 해시·실행 영수증·종료 코드와 정리 readback을 기록했다. Swift 5 모드에서 async enable의 기존 non-Sendable StreamServer 캡처 경고가 남는다. 경고를 숨기거나 임의 Sendable 적합성을 추가하지 않았다.

이 결과는 생산 메서드의 대역 I/O 검사다. 전체 앱 빌드·실제 Network.framework 송신·기기 수용·설치·호스트 교체의 증거가 아니며 구현자의 검토를 최종 독립 검수로 사용하지 않는다.
