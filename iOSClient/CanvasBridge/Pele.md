# 그림판의 Pele 다이어그램 계약

`CanvasScene.nodes`와 `links`가 정본이다. `CanvasDiagramSnapshot`은 같은 UUID와 revision에서 Mermaid를 도출한다. 자동 배치 좌표를 원본 `frame`이나 Pencil 획에 쓰지 않는다. 화면의 원본 그림, 다이어그램, 나란히 보기는 같은 Store를 사용한다. 다이어그램의 노드를 누르면 기존 구조 데이터 검사창과 내용 편집기로 이어진다.

알려진 요소와 관계는 장면 변경 시 갱신한다. 원본 획만 바뀌면 기존 SVG를 재사용하며 클릭의 revision은 갱신한다. 자유그림의 자동 의미 해석은 구현하지 않았다. Pencil Scribble와 키보드의 텍스트 입력은 기존 편집기를 사용한다.

`AgentRevision`은 기존 필드와 호환되는 선택적 `nodeEdits`, `linkEdits`를 받는다.

```json
{
  "sceneId": "장면 UUID",
  "baseRevision": 3,
  "annotations": [],
  "proposedNodes": [],
  "nodeEdits": [{"expected": "수정 전 CanvasNode 객체 전체", "text": "수정할 본문"}],
  "linkEdits": [{"expected": "수정 전 CanvasLink 객체 전체", "replacement": "같은 UUID의 CanvasLink 객체 전체"}]
}
```

실제 JSON에는 설명 문자열 대신 해당 객체를 넣는다. 본문은 정확한 UTF-8 바이트와 노드의 기대 상태를 비교한다. 연결된 vault 노드의 본문 직접 수정은 거부한다. 관계 수정은 같은 관계 UUID, 유효한 끝점과 기존 계층 규칙을 확인한다. 수정과 추가가 섞인 batch는 전부 성공하거나 전부 거부된다. 새 수정은 현재 revision에서만 적용한다. 이미 반영된 동일 결과의 재수신은 revision을 올리지 않는다. 중복 대상, 다른 본문의 재전송과 오래된 덮어쓰기는 거부한다.

UI의 확정과 AI의 기존 노드 수정은 `CanvasScene.editGraph`를 사용한다. 구조 수정 되돌리기는 마지막으로 적용한 구조 변경 하나를 복원하며, 현재 구조가 그 결과와 일치할 때만 실행한다. 이후 추가된 원본 획과 PencilKit 데이터는 유지한다. 다른 구조 수정이나 원격 갱신 뒤에는 잘못된 되돌리기를 허용하지 않는다.

`CanvasLink`의 `fromAnchor`와 `toAnchor`는 선택값이다. 값은 `{"side":"right","offset":0.5}` 형식이며 `side`는 `top`, `right`, `bottom`, `left` 중 하나다. `offset`은 0부터 1 사이의 유한한 수다. 위·아래 변은 왼쪽에서 오른쪽, 좌·우 변은 위에서 아래로 잰다. 없거나 null이면 상대 노드 중심 방향의 사각형 경계에 자동 부착한다. 저장된 연결점은 노드 이동과 크기 변경 뒤에도 같은 변과 비율을 유지한다. 잘못된 연결점과 넓이·높이가 0 이하이거나 유한하지 않은 프레임은 연결 계산·수정에서 거부한다.

AI의 `expected`에는 수정 전 두 연결점도 포함해야 한다. 수정하지 않는 연결점은 `replacement`에 그대로 넣는다. 기존 `sameLink`, `editGraph`, 원자적 batch와 멱등 재수신 검사가 두 연결점을 함께 비교한다. 구형 AI가 현재 연결점을 누락한 기대 상태로 덮어쓰면 거부한다. `sceneJSONBase64`, 파일 내보내기와 자동 저장에는 같은 Codable 모델이 들어간다. Mermaid는 노드 UUID와 연결 의미를 투영하며 연결점 좌표를 저장하는 형식으로 쓰지 않는다.

원본 그림의 요소 이동 모드에서 선을 선택하면 두 끝점 손잡이가 나타난다. Pencil이나 손가락으로 각 끝점을 끌면 그 끝점의 기존 노드에서 가장 가까운 경계로 이동한다. 드래그 미리보기는 선택 상태에만 있고 저장 revision을 올리지 않는다. 종료 시 전체 링크 기대 상태와 scene generation을 다시 확인한다. 드래그 중 외부 변경이나 도구·장면 전환은 오래된 확정을 막는다. 확정은 기존 구조 되돌리기에 기록한다. 다시 실행도 같은 변경 전후 쌍을 사용하며 최신 원본 획을 보존한다. 실행 이력은 재실행 후 복구하는 영구 원장이 아니다.

화면과 PNG 내보내기는 같은 `CanvasScene.linkEndpoints` 계산을 사용한다. 기존 CCR의 유향 화살표와 `from`·`to` 의미는 유지한다. 원앱에서 관측한 무화살촉 선으로 변환하거나 자동 손그림 인식을 구현하는 범위는 아니다.

연결점 검사는 기기나 UI를 열지 않는 기존 실행기 옵션을 사용한다.

```sh
python3 -B Tests/checks/pele-live/run.py /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/diagram-endpoints-20261023/verification --diagram-endpoints
```

이 옵션은 모델·Store와 기존 graph 검사, NativeSceneEncoder 왕복, 전체 CanvasBridge의 iOS SDK 타입 검사를 수행한다. 화면 입력·PNG 픽셀과 실제 동기화 수용은 실기기 후속 검증으로 남긴다.

오프라인 리소스는 npm `pele@1.6.0`의 브라우저 번들이다. 원래 플러그인의 lockfile SHA-512와 대조했으며 SHA-256과 MIT·ISC 라이선스를 `Pele/provenance.json`과 `Pele/LICENSE.txt`에 포함했다. Xcode는 `CanvasPeleView.swift`와 `Pele` 리소스 폴더를 수동 등록한다. 런타임 npm 설치는 필요 없다.

WebKit은 비영구 데이터 저장소를 쓰며 로컬 리소스 폴더만 읽는다. CSP는 네트워크·이미지·프레임·객체 로딩을 차단한다. Pele의 링크와 이미지는 비활성화한다. 원본은 50,000 UTF-8 bytes, 요소 512개, 관계 1,024개, SVG는 1,000,000 bytes로 제한한다. 파싱한 노드 ID와 SVG의 실제 노드 ID를 기대한 UUID 목록에 대조한다. 선택 메시지는 장면 ID·revision·최신 snapshot을 native에서 다시 확인한다.

검증 명령은 다음과 같다.

```sh
python3 -B Tests/checks/pele-live/run.py /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/pele-rea-20261021/pele-worker
```

이 검사는 production 모델과 Store, 창을 만들지 않는 native WebKit, 기존 relay의 격리 ObsidianVault 저장을 사용한다. 실제 iPad UI 검사는 `testPeleNodeEditAndSave`이며 부모가 격리된 iPad 테스트 컨텍스트에서 실행한다. `fixtures/pele-graph.json`은 격리 상태에만 주입한다. 실제 사용자 그림과 vault를 대체하지 않는다.

기존 `CanvasWorkspace`의 refresh·CAS 저장 경로를 사용하므로 별도 서버는 필요 없다. 현재 relay Markdown은 구조 텍스트 목록을 생성한다. Obsidian Markdown에도 Pele를 직접 표시하는 범위는 부모의 relay 변경이 필요하다. 변경 지점은 `relay/obsidian-vault.js`의 `canvasStructure(scene)`이며, `CanvasDiagramSnapshot`과 같은 UUID ID 변환·텍스트 escape·표시 범위·크기 제한으로 파생 Mermaid 블록을 추가해야 한다. `baseSha256`은 계속 Markdown SHA를 사용한다.
