# iPad 연결선 끝점 편집

작업 `ipad-diagram-endpoints-20261023`, 원담당 `01a13ace-e372-7ed1-9946-149df37ee1c3`.
기준 `ed05bc9095e316ffbed8bb29ad052e15c9c6904e`, 전용 브랜치 `codex/ipad-diagram-endpoints-20261023`.

- [x] 1. `how` over the affected subsystem.
- [x] 2. `architect` for parallel design exploration.
  skip: 사용자 ARENA 및 같은 후보 경쟁 금지에 따라 지정된 기존 구조를 직접 조사하고 단일 설계를 적용한다.
- [x] 3. Write the throughput checkpoint as four todo items.
  - [x] **Blocking first steps.** 최신 결정, 스킬, WT 지침, 기준 HEAD와 clean 상태, 저장 경로를 확인했다.
  - [x] **Independent workstreams.** 단일 기능의 모델·Store·UI·시험은 한 구현자가 소유한다. 부모는 외부 REA와 Booster 작업을 소유한다.
  - [x] **Shared mutable state.** 전용 WT만 쓴다. 공유 UI·호스트·오디오·Booster·relay·기기에는 쓰지 않는다.
  - [x] **Smallest safe decomposition.** 기존 Codable, editGraph, graphUndo, autosave를 확장한다. 새 패키지·서버·의존성이 필요하지 않다.
- [x] 4. Delegate code-writing to a subagent using your configured feature model.
  사용자에게 독립 구현을 위임받은 구현자가 직접 작성한다. 독립 검수는 부모가 후속 수행한다.
- [x] 5. Verify on the matching surface.
  SDK 모델·Store 실행과 iOS SDK typecheck를 한다. 기기·공유 UI 실행은 사용자 지시로 제외하며 실기기 수용을 주장하지 않는다.
- [x] 6. Rebase into small, ordered commits. Stack follow-ups.
  기준 브랜치가 고정된 전용 WT이므로 불필요한 rebase 없이 검증한 로컬 커밋을 만든다.
- [x] 7. If the design is contested, `interrogate` before shipping.
  n/a: 데이터 구조와 범위가 사용자 지시로 확정됐다. 배포하지 않는다.
- [x] 8. Run **Opening a PR**.
  skip: 외부 push·PR·배포 금지.

## 기존 경로와 설계

CanvasScene의 CanvasLink에 optional fromAnchor/toAnchor를 붙인다. Anchor는 side와 finite 0...1 offset이다. nil은 상대 중심 방향의 사각형 경계다. CanvasModel의 순수 계산을 화면과 PNG가 공유한다.

CanvasStore.scene은 didSet에서 자동 저장한다. 드래그 미리보기는 별도 임시 값이며 원장 revision을 바꾸지 않는다. 시작 시 scene generation과 링크 전체를 보관한다. 종료 시 generation과 expected를 확인해 editGraph로 한 번만 반영하고 기존 graphUndo 전후 쌍을 기록한다. 같은 전후 쌍을 사용하는 graphRedo를 추가한다. 새 획을 되돌리지 않는다.

CanvasWorkspace의 원본 그림에서 select 모드일 때만 선 선택과 두 끝점 핸들을 표시한다. endpoint는 자신의 기존 노드 경계에만 투영한다. Mermaid는 기존 노드 UUID와 연결 의미 투영을 유지한다.

CanvasRelay는 JSONEncoder의 전체 CanvasScene을 sceneJSONBase64로 전송한다. SceneFile, CanvasPacket, NativeSceneEncoder, importScene, autosave, Vault restore, AI 기대/대체·재수신 경로를 함께 검사한다. 외부 relay는 읽기 전용으로 조사하고 정확한 차이를 보고한다.

Model the Domain 원칙에 따라 Anchor·Endpoint·임시 드래그 자료를 명시한다. Ponytail full은 기존 파일·변경 전후 Undo 쌍과 표준 Codable 재사용에 적용한다.

## 완료 게이트

- [x] 모델·AI 검증과 역호환 JSON
- [x] 선택·끝점 드래그·stale 거부와 Undo·Redo
- [x] 저장·재열기·Obsidian 격리 왕복
- [x] 관련 기존 graph 검사와 iOS SDK typecheck
- [x] 외부 relay 및 typed scene 왕복 경로 조사
- [x] 로컬 커밋과 부모 독립 검수 인계 자료 준비

독립 검수는 부모의 후속 단계다. 이 구현자의 자체 diff 확인과 자동 검사는 독립 검수로 세지 않는다.

## typed scene 왕복 조사

| 경로 | 결과 |
| --- | --- |
| `CanvasStore.restoreScene/saveNow` | 같은 CanvasScene Codable 모델로 양쪽 연결점 보존. 실제 새 Store 재열기로 검증했다. |
| `CanvasWorkspace.fileImporter`와 `SceneFile` | 같은 CanvasScene 디코딩·인코딩 사용. 별도 축약 링크 구조가 없다. |
| `CanvasRelay.saveVaultCanvas`와 `CanvasWorkspace.refreshCanvasFromVault` | 전체 sceneJSONBase64를 전송·디코딩한다. prefix 검사는 links 전체 Equatable을 비교해 연결점 차이도 감지한다. |
| `CanvasPacket.init/frozenScene`와 outbox | 전체 장면 JSON과 SHA를 보관한다. 패킷 왕복을 실행했다. |
| `AgentRevision`의 expected/replacement/proposedLinks | 공통 CanvasLink Codable과 hasValidAnchors, sameLink, editGraph를 사용한다. 원자적 거부·재수신을 실행했다. |
| `Scripts/ipad-test-runtime/NativeSceneEncoder.swift` | 실제 실행해 JSON 객체 전체가 동등함을 확인했다. adapter의 동일 모델 encoder 경로다. |
| `CanvasDiagramSnapshot`와 Pele | 원본 CanvasScene에서 Mermaid·노드 UUID를 읽는 파생 표시다. Mermaid를 CanvasScene으로 역변환하지 않는다. 좌표 생략은 원본 연결점 유실 경로가 아니다. |
| `SceneRenderer.png` | 원본에서 파생 PNG를 생성한다. 화면과 같은 linkEndpoints를 사용하며 원본 JSON은 별도 유지한다. iOS SDK 타입 검사 대상이다. |
| 정본 Node relay의 ObsidianVault·packet·codex-delivery | raw scene bytes 또는 scene.links 객체 전체를 유지한다. 큰 inline context 생략은 원본 파일을 보존하는 기존 계약이다. |

relay 정본은 `/Users/ambrion/Documents/ChatGPT/BT_CCR-Obsidian-relay`, 읽어 확인한 clean HEAD는 `aae5a434ed2e12dc8e216f8a1cc1a4d678525126`이다. 부모의 `../relay-anchor-roundtrip.cjs`와 `../relay-anchor-roundtrip-result.json`을 읽었다. 8개 검사에서 새 ObsidianVault 인스턴스 재열기 exact bytes, Mac 쪽 revision·연결점 변경 readback, Mermaid 의미 유지, stale 409와 원본 보존을 확인한 영수증이다. relay 소스 무변경, 실제 사용자 vault 쓰기 0, 공유 서버 변경 0이다. 같은 시험을 중복 실행하지 않았다.

정본 저장소 안 `CanvasBridge/CanvasModel.swift`는 오래된 prototype의 별도 Swift 모델이며 anchor·kind·vault 확장 필드가 없다. 그 구형 앱의 import, SceneFile, autosave, packet frozenScene을 거쳐 재인코딩하면 해당 필드는 사라진다. 이 구형 Swift 모델은 현재 iPad Xcode 대상이나 정본 Node relay의 ObsidianVault 처리 경로에서 사용하지 않는다. 수정하거나 실행·설치하지 않았다. 구형 앱을 현재 장면의 편집기로 재사용하는 것은 별도 호환 작업이다.

## 검사 진행

첫 전용 검사 컴파일에서 테스트의 throwing Boolean 표현식에 `try` 표기가 부족해 실패했다. 직렬화 바이트 비교를 sameBytes로 정리한 뒤 컴파일과 실행이 통과했다. 제품 기능을 완화하지 않았다.

현재 같은 소스 검사에서 `ENDPOINT_CHECKS assertions=190`, 기존 `canvas-hierarchy` 142개, `HIERARCHY_FOLD_CHECKS assertions=41`과 기존 revision·혼합 graph·Store 검사가 통과했다. NativeSceneEncoder 전체 JSON 왕복도 통과했다. 전체 실행 영수증은 `../verification/result.json`에 기록한다.

최종 실행 명령은 `python3 Tests/checks/pele-live/run.py /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/diagram-endpoints-20261023/verification --diagram-endpoints`이다. 17개 실행 항목의 exitCode가 모두 0이며 최종 exitCode도 0이다. 검사 전후 입력 해시가 같고 커밋 직전 readback에서도 일치했다. 전체 CanvasBridge에는 CanvasWorkspace와 SceneRenderer가 포함된다. iOS SDK 타입 검사에서 기존 CanvasDictation의 installTap 및 SceneRenderer의 UIScreen.main 사용에 대한 deprecated 경고 2개가 남았고 오류는 없다.

Pstack Feature 경로의 how 조사는 현재 Codable·그래프 mutation·Store undo·SwiftUI·PNG·relay 연결을 추적했다. ARENA 금지에 따라 architect의 경쟁 단계는 수행하지 않았다. 구현은 위임받은 전용 WT에서 직접 수행했고 추가 담당이나 순정 Goal을 생성하지 않았다. Model the Domain은 정규화 Anchor와 Endpoint, 임시 드래그 상태를 분리하는 선택에 적용했다. Ponytail full은 기존 경로와 마지막 graphUndo 전후 쌍을 재사용하는 선택에 적용했다. Sequence work into verifiable units에 따라 모델·Store·기존 graph를 먼저 확인하고 NativeSceneEncoder와 SDK 검사를 완료했다.

deslop 자체 점검과 `git diff --check`를 완료했다. 새 제품 코드 주석은 0개이며 관련 없는 리팩터링·의존성·서비스·설정 변경은 없다. no-comments를 포함한 독립 검수는 사용자 지정대로 부모가 후속 수행한다. 자체 diff 확인·컴파일·자동 검사로 독립 검수 CLEAR를 대신하지 않는다.

화면과 PNG의 화살촉은 기존 CCR 유향 계약 그대로다. 원앱에서 관측한 무화살촉 선과의 동일성, 자동 손그림 인식, 전체 MyScript 복각을 주장하지 않는다. 부모의 독립 검수 후 실기기에서는 선 선택·두 endpoint Pencil/손가락 입력, 확대·이동 좌표, 그리기·지우기 방해 없음, Undo·Redo, 저장·재열기와 PNG/수신함의 위치를 확인해야 한다. 이 작업은 설치·기기 실행·호스트 교체·공유 UI·오디오·Booster·운영 vault 변경을 수행하지 않았다.
