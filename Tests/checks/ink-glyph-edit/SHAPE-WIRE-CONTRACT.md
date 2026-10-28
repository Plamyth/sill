# Shape wire 계약의 현재 상태

전체 shape 수용은 false다. glyph 순수 note 접합 a8810155는 독립 CLEAR를 받은 별도 단위로 보존한다. 원소유 e529975의 Kind 확장은 공통 wire 변경이다. 최초3912af4는 새 종류를 전면 거부했으며 이력은 해당 commit에 보존했다. 현재 규칙은 DIAGRAM-PROJECTION-v1.md를 따른다. 세부 schema/DSL은 사용자 요구를 구현하기 위해 조율 담당이 선택한 계약이다.

| 경계 | 현재 처리 | 남은 단계 |
| --- | --- | --- |
| 구형68 | Kind note/box만 엄격 해독. schema3/새 kind는 읽을 수 없음 | 새 앱 설치 전 신구 소비자 혼합 정책과 원본 보존 검수 |
| CanvasScene | 1/2 note·box 유지,3에서 ellipse·line 허용. unknown은 명시 거부 | 최종 exact source에서 regression |
| 생성·편집 | shape/원격 새 kind→3. glyph·그리기·펜 설정·원격 수정은3보존 | 실제 인식·Pencil 수용 |
| Files | 원본 native/frame/rotation/출처 세대 저장. 실패·취소·CAS는 이전 원본과 미저장 복구본 유지 | iPad 실제 provider/북마크 |
| CanvasDiagramSnapshot·Pele | 고정 퍼센트 타원, 실제 edge+숨은 endpoint의 선. 표시 helper 상한 포함 | iPad 실제 UI·최종 시각 수용 |
| CanvasRelay | schema3 GET capability 확인 후에만 PUT/POST. 미지원/거부면 대기/실패 | Galileo 짝 relay exact commit 통합 및 실제 파일 의미 왕복 |
| 원본 relay f61f516 | 새 kind를 의미 지원하지 않음. 모든 노드는 상자 Mermaid, 설명은 note/box 외 요소 | 부모가 별도 worker로 공식 저장소 CanvasRelay에 출처 보존 편입 중 |

원본 relay HEAD는 f61f51696aa5cd5b1973277a347ffca3f534fa26이며 모듈 SHA는 shape-wire-contract.json에 있다. source commit을 공유 서버의 설치 버전으로 주장하지 않는다. 원본 서버/사용자 데이터 수정0이다. raw JSON 왕복만으로 ellipse/line 의미 왕복 완료로 세지 않는다.

포인터: CanvasModel.swift의 CanvasScene.requireCompatibleNodeKinds/promoteSchemaForNodeKinds/CanvasDiagramSnapshot/CanvasFileWorkspace.save, CanvasInkShapeProposal.confirmed, CanvasInkTextEditing의 schema 보존, CanvasStore의 updateDrawing/persistScene/fileWorkspaceCanSync, CanvasRelay의 requireSceneSupport/saveVaultCanvas/send, CanvasPeleView 및 Pele/bridge.js, CanvasWorkspace의 NodeTile 선택 layout.
