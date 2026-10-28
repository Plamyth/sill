# 원본을 보존하는 참조 카드 병합

기준: 공식7fa8da53/tree429a3e52. 원앱 근거는 보존된 `margin-card-merge-corrected-spec.md`와 `margin-card-merge-audit-acceptance.json`이다. MarginNote Mac 자체 Alpha/Beta의 실제 병합·명시 해제·Undo/Redo 화면과 공식 백업을 관측했으며 메뉴 문자열만이 아니다. iPad·cold restart·복합 카드 전체의 수용은 아니다.

제품의 최소 단위는 **출처를 유지하는 병합 표시 카드**다. 선택한 순서대로 원본 note.text를 새 note에 복사하고 기존 general 링크의 `병합 원본 · N` 라벨로 원본 nodeID 순서를 보존한다. 기존 Annotation의 한국어 author/text 표식으로 병합 자료를 구분한다. 새 scene 필드·kind·DB·relay 계약은 없다. 원본 노드·vaultNote/PDF Markdown provenance·원본 획·주석·부모자식 관계는 그대로 유지하며, 원본 카드를 숨기거나 본문을 이동하지 않는다. 병합 표시가 자동으로 최신 원문과 같아진다고 주장하지 않는다. 최신 원본은 병합 메뉴에서 원본 카드를 선택한 후 기존 원문 열기 경로로 확인한다.

명시 해제는 확인된 병합 링크/표식만 제거한다. 합친 본문과 병합 뒤 사용자 수정도 남긴다. 실제 원앱이 남긴 빈 부모/아카이브 바이트 배치를 복제하는 단위는 아니다. 일반 노트·PDF 원본을 하나의 새 노트 ID로 치환하지 않는다. 계층 재구성·원본 이동·중첩 병합은 이 단위에 포함하지 않는다. 단순 텍스트 이어붙이기와 달리 원본 ID·vault 참조·선택 순서가 JSON에 왕복된다.

선택 모드에서 첫 카드로 병합 준비 → 다른 카드를 선택해 다음 순서로 추가 → 명시 확정한다. 같은 source SHA/장면세대·마지막 선택세대를 확인하며 scene/mode/Pencil 변화와 취소는 원본을 바꾸지 않는다. 열린 편집·원문 충돌·Files blocked·native busy는 기존 공통 guard로 거부한다. 새 카드와 해제, 해당 공통 Undo/Redo는 복구본을 먼저 저장하고 성공 후 메모리를 바꾼다. Files 저장은 기존 pending/ready/blocked와 CAS 경로를 사용하며 별도로 표시한다.

실행:

```sh
python3 Tests/checks/card-merge/run.py --output /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-completion-20261028/card-merge-evidence --sdk-check
node Tests/checks/card-merge/relay.cjs <위 실행이 출력한 run-UUID 경로>
```

첫 명령은 실제 Model/Store/PKDrawing과 파일 생성·새 Store 재열기·순서/출처/계층 보존·공통 Undo/Redo·캐시/Files IO 실패·외부 Markdown 파일 수정 수신·Files CAS 충돌과 취소/ABA를 검사한다. macOS27 fixed-HOME 아래 즉시 stale가 되는 minimal bookmark 반례는 보존하고, 테스트가 소유한 폴더의 macOS scoped bookmark를 사용한다. 제품의 bookmark/stale 보호는 변경하지 않는다. `--ccr-test-runtime`과 격리 HOME, 일반 상태 sentinel 해시를 사용한다. PNG preview는 주입 fixture이며 실제 렌더/UI 수용이 아니다.

두 번째 명령은 실제 기존 ObsidianVault 모듈을 자체 오프라인 디렉터리에서 실행해 JSON 원바이트·원본 참조/순서·Markdown 표시·새 인스턴스 재열기·stale CAS 원본 보존을 검사한다. 서버/HTTP/사용자 vault를 실행하거나 수정하지 않는다. SDK는 현재 CanvasBridge 전체의 iOS27 arm64 타입을 검사한다. 정상 앱 bundle/Team/build 버전·서명·설치·키·기기·Host·서비스는 변경하지 않는다.

기능 source 수용은 독립 검수 전 pending이며, UI/터치·설치·실물·원앱 전체 동등성 완료는 false다. PDF/일반노트 writer와 소유 구간을 직접 조율했고 Model/PDF 원문/복구 함수·NodeTile·내보내기 코드는 변경하지 않는다. 문서4파일 커밋7e85/e7be는 별도 브랜치에 보존한다.
