# Files 작업 원본 검사

실제 Apple Foundation/PencilKit 파일을 쓰고 새 인스턴스로 다시 읽는다. UIKit을 사용하는 Catalyst 검사는 실제 SceneRenderer로 PNG를 만든다. 격리한 HOME과 외장 증거 폴더만 사용하며 앱 설치·실기기·실제 문서·네트워크에는 접근하지 않는다.

```sh
python3 Tests/checks/canvas-file-workspace/run.py /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-completion-20261028/storage-evidence/checked
```

실행마다 별도 fixture 폴더를 사용한다. 현재 Xcode의 macOS/iOS 27 SDK가 필요하다. 결과 JSON과 각 컴파일/실행 로그를 출력 폴더에 기록한다.

사용자가 고른 폴더의 `<scene UUID>.sill/current.json`이 현재 원본 세대를 지정한다. `revisions/<generation UUID>/scene.json`은 기존 CanvasScene JSON이고 `drawing.pkdrawing`은 그 장면의 drawingBase64를 디코딩한 원본 바이트다. `preview.png`는 같은 장면에서 생성한 이미지다. current.json은 세 파일의 SHA-256과 scene identity를 담으며 마지막에 원자 교체한다. 파일 조정 안에서 이전 토큰과 세 파일 해시를 검사한 뒤 쓰므로 외부 변경을 덮지 않는다. 중단된 세대는 current.json에 연결되지 않는다. 과거 세대와 중단 세대의 자동 삭제는 구현하지 않았다.

외부 도구가 수정할 때는 세 파일을 일치시키고 새 세대와 해시를 게시해야 한다. scene.json만 고치면 불일치로 보존·중단한다. 기존 relay/CAS payload와 서버 계약은 바꾸지 않았다. Files 원본을 선택한 뒤 미저장 또는 실패 상태이면 그림 relay의 전송과 역방향 적용을 막는다. Files binding과 선택 폴더가 전혀 없으면 기존 Obsidian 경로를 허용하며, 기존 화면의 canvasVaultEnabled와 relay/CAS 검증은 그대로 적용한다. 실제 relay 통신 시험은 이 검사 범위 밖이다.

자기 앱 Documents/ApplicationSupport는 외부 원본으로 수용하지 않는다. 기존 CanvasScene.json의 Legacy 원문은 첫 전환 전 CanvasLegacyScene.json에 복사하고 바이트 해시를 대조한다. 문서를 열기 전 현재 장면은 CanvasPending-UUID.json으로 복사·해시 확인한다. 기존 CanvasScene.json은 이후 캐시·미저장 복구본으로만 쓰며 실패를 Files 저장 성공으로 표시하지 않는다.

실제 iPad에서 폴더 picker, security scope의 재시작 지속성/권한 회수/stale bookmark, iCloud·Obsidian FileProvider, 화면 배치와 Pencil 입력은 별도 검증이 필요하다. 복구본의 독립 서재 UI와 세대 정리는 이번 최소 기능에 포함하지 않는다. 네이티브 검사는 비sandbox macOS이므로 iPad provider 권한 수용을 대신하지 않는다.

`safety.swift`는 재시작 시 로컬 C/binding A/외부 B 충돌과 binding B/cache A 기록 중단을 실제 파일로 구성한다. 충돌 후 재시도는 신뢰한 토큰과 저장 기준 장면의 해시가 현재 원본과 둘 다 같을 때만 허용한다. 알 수 없는 저장 세대는 원본 다시 열기 또는 다른 폴더 안전 내보내기로 처리한다. 미리보기 대기 중 취소한 Task는 원본 세대와 binding을 갱신하지 않는다.

손상된 내부 캐시가 정상 외부 문서 열기를 막지 않도록 원문을 `CanvasUnreadable-UUID.json`에 복사·해시 확인하고, 현재 메모리 장면도 별도 `CanvasPending-UUID.json`에 보존한 뒤 검증된 외부 장면으로 전환한다. 대상 열기 실패 시 기존 손상 바이트와 메모리 장면을 유지한다. 이 경로의 저장·재시작·취소 검사는 실제 격리 파일에 대해 수행한다.
