# 다음 획의 펜 설정과 잉크 스타일

펜 색은 `white`, `yellow`, `cyan`이고 굵기는 캔버스 포인트 `2`, `4`, `8`이다. CCR 자체 선택이며 원앱 옵션·설정 저장 동등성을 주장하지 않는다. 메뉴의 선택은 다음 펜 획에 적용한다. 지우개·자·기존 획은 바꾸지 않는다.

`CanvasScene.penSettings`는 `version`, `color`, `width`를 저장한다. 누락된 legacy 장면은 다음 펜 설정만 흰색·4포인트로 읽는다. 기존 획의 실제 색이나 명목 굵기를 이 기본값으로 추정하지 않는다. 설정 또는 native 스타일 투영이 추가된 장면은 `schemaVersion=2`다. 새 reader는 1과 2를 지원하고 기존 reader의 schema 1 검사로 새 장면 재저장이 차단된다.

UI는 `CanvasStore.choosePenSettings`에서 `setPenSettings`를 호출한다. 에이전트는 기존 relay의 revision 응답에 아래 입력을 넣는다. 배열은 기존 AgentRevision 계약대로 필수다.

```json
{
  "sceneId": "현재 장면 UUID",
  "baseRevision": 12,
  "annotations": [],
  "proposedNodes": [],
  "setPenSettings": {
    "expected": { "version": 1, "color": "white", "width": 4 },
    "settings": { "version": 1, "color": "cyan", "width": 8 }
  }
}
```

`CanvasScene.setPenSettings`가 장면 ID, revision, 기존 설정, 허용값, 입력 중 상태와 장면 크기를 공통 검증한다. Store는 native 가독성을 확인하고 기존 atomic 장면 저장 성공 후에만 메모리에 적용한다. 반환값은 `CanvasPenSettingsResult`의 `applied` 또는 `noop`, 실제 설정과 revision이다. 에이전트 경로는 기존 Bool 반환을 유지하고 Store의 장면과 상태에서 결과를 읽는다. 정확한 기준에서 같은 설정을 요청하면 저장·revision·이력이 바뀌지 않는다. 오래된 명령 재시도는 `stale_revision`이다.

| 코드 | 의미 |
| --- | --- |
| `stale_revision` | 장면 ID, revision 또는 기존 설정이 다르다. |
| `invalid_pen_settings` | 설정 버전·색·굵기가 지원 범위를 벗어났다. |
| `ink_busy` | Pencil trace 또는 native tool이 사용 중이다. |
| `unsupported_ink_edit` | 기존 획 수정·opaque drawing 교체·미지원 필드 또는 graph와 펜 명령 혼합이다. |
| `unreadable_drawing` | 기존 native drawing 또는 보존 장면을 읽을 수 없다. |
| `unsupported_ink_projection` | 스타일 버전·점 대응·값 또는 native 원본을 확인할 수 없다. |
| `scene_too_large` | 로컬 장면의 4 MiB 한도를 초과한다. |
| `pen_settings_not_saved` | 저장이 실패했다. 기존 메모리 설정을 유지한다. |

`AgentRevision.apply`와 `CanvasStore.applyAgentRevision`이 같은 펜 검증을 사용한다. 펜 명령은 graph 편집과 섞지 않는다. 기존 획의 재색칠·폭 변경·마스크 수정·`drawingBase64` 교체는 입력 계약에 없다. 자동 revision 조회도 도메인 거부를 표시하고 같은 잘못된 응답을 반복 적용하지 않는다.

`InkStroke.style`은 조회용 투영이다. `version=1`, `inkType`, sRGB `color`의 red/green/blue/alpha, `transform`의 a/b/c/d/tx/ty, `samples`의 width/height/opacity를 제공한다. samples는 원본 path 점 인덱스에 대응하고 size는 path-local 단위다. 기존 points는 world 좌표와 pressure다. transform은 원래 path에서 world로 가는 변환이다. 마스크 가시 구간과 보간 경계점은 기존 visibility를 유지한다. 색이 nil이면 sRGB 해석 불가이며 style 자체가 nil이면 legacy unknown이다.

투영은 저장할 원본 PKDrawing 바이트를 Apple decoder로 읽은 뒤 만든다. in-memory native drawing, ID, metadata, mask와 UndoManager는 그대로 유지한다. 스타일 필드로 PKDrawing을 재구성하지 않는다. 스타일이 있는데 native 원본이 없는 구조-only 장면은 가져오기와 PNG에서 거부한다. legacy 구조-only fallback은 기존 최선 표시를 유지한다.

로컬 장면 한도는 4 MiB이며 기존 대화 패킷은 1 MiB다. SceneFile·CanvasRelay와 ObsidianVault의 기존 generic JSON 경로를 사용한다. 자동 동기화의 prefix 안전 비교에도 다음 펜 설정 동일성이 필요하다. 테스트는 실제 ObsidianVault 모듈의 격리 파일 왕복이며 live HTTP·Obsidian 화면·실제 Pencil 입력 수용을 뜻하지 않는다.

순수 명령 회귀는 `python3 Tests/checks/ink-transform/settings-run.py <storage-route 외장 출력 경로>`로 Mini에서 실행한다. native 및 SDK 검사는 기존 `ink-transform/run.py`, `ink-visibility/run.py`, `ink-undo/run.py`, `linked-obsidian-notes/run.py`를 사용한다. 설치와 최종 실물 입력은 부모 담당의 검증 묶음에서 별도로 수용한다.
