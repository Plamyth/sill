# 현재 개요 텍스트 PDF

`현재 개요 PDF`는 기존 개요 UI와 같은 카드 순서·깊이·초점·태그·열린 그룹 범위의 읽기 전용 스냅샷을 내보낸다. 빈 카드는 `이름 없는 요소`로 포함한다. CoreText로 텍스트를 그리며 긴 내용은 페이지를 나눈다. 안정 ID와 원문 참조를 가진 canonical scene·문서, 잉크와 기존 페이지 PNG/PDF 경로는 보존한다. 이미지 첨부나 원앱 딥링크를 새로 만들지 않는다.

문서·페이지·선택·보기 owner와 source SHA를 대조한다. 태그 필터 왕복도 이전 owner를 무효화한다. 기존 `RenderedExportState`와 `fileExporter` 하나를 재사용하며 준비 중 중복 실행, 취소된 결과의 재표시와 다른 요청의 늦은 완료를 거부한다.

실행 명령은 다음과 같다. 출력은 storage-route가 확인한 외장 보관 경로 아래의 이 작업 증거 폴더로 제한한다. 검사에는 Mac SDK의 CoreText·PDFKit·PencilKit이 필요하다.

```sh
python3 -B Tests/checks/canvas-outline-export/run.py --output /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-followup-20261103/outline-export-evidence/native-01
```

실제 CanvasStore의 범위·owner·원본 불변과 제품 PDF helper의 한국어·빈 제목·계층·긴 문단·페이지 경계·저장/재열기·취소·잘못된 입력을 검사한다. 기존 DocumentFiles로 저장한 canonical document의 재열기에서 같은 ID·순서·본문·참조와 PDF 텍스트를 확인한다. 정상 token CAS로 외부 본문/revision을 갱신하고 기존 Store 수신 경로 및 새 프로세스의 snapshot/PDF 반영을 확인한다. 이는 canonical 원본을 읽는 PDF 투영의 검사이며 PDF 역동기화가 아니다. EPUB wholeFiles/CAS 검사는 기존 계약의 별도 회귀다.

source-before/after, 명령·시각·결과와 PDF 해시를 `result.json`으로 반환한다. 실제 HTTP는 실행하지 않는다. SwiftUI 저장 패널, iPad 설치·실물·Pencil, 원앱 전체 개요 동등성, 이미지/딥링크 수용은 검증하지 않는다. 독립 검수와 통합은 부모 담당이 수행한다.
