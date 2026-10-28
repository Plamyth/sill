# 선택한 원본 획의 도형 보정 후보

부모 목표는 `/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-completion-20261028/GOAL_PROMPT.md`, 부모 작업 원장은 `../program/units.tsv`의 `ink-shape-proposal` 행이다. 새 목표나 반복 실행을 만들지 않는다.

기준은 `c03d9c2de9eb39cfd50501a73a060a0a34375c8c`, tree `a912b7d899ebf6bfbc08311461082165f630c2c0`이다. Pstack의 how → architect → 구현 → 실제 산출물 검증 경로를 사용한다. ARENA 및 대체 경쟁 설계는 실행하지 않았다. Ponytail full의 기존 구조 재사용을 적용해 `CanvasNode`, `sourceStrokeIds`, `.proposal/.confirmed`, `CanvasRect`, 회전, `PKDrawing`, 기존 구조 Undo/Redo와 저장기를 재사용한다. 별도 도형 저장소·인식 의존성은 만들지 않는다. 상태를 한 후보 값으로 묶는 Model the Domain 원칙과 실제 파일을 다시 읽는 Prove It Works 원칙을 적용한다.

부모의 병렬 분해를 유지한다. 이 writer는 새 도형 파일과 이 검사 폴더만 소유한다. 저장 writer의 Model/Store/Workspace 및 glyph writer의 `CanvasInkTextEditing.swift`를 직접 수정하지 않는다. 소유 파일의 구현·검사는 독립적으로 진행하고 통합과 공유 화면/기기는 부모가 소유한다. 현재 실행 환경에는 `spawn_agent` 도구가 없어 추가 하위 검수자를 만들지 않았다. 독립 검수는 부모의 별도 reviewer가 해야 하며 자체 검사를 독립 검수로 세지 않는다.

## 적용 방법

소유 커밋을 통합 writer가 검수한 뒤, 해당 writer의 소유 워크트리에서 `git apply --check Tests/checks/ink-shape-proposal/integration.patch`로 대조한다. 그 writer가 접합 패치를 반영한다. 여기서는 push·병합·설치하지 않는다.

접합 패치는 Model의 노드 종류에 `ellipse/line`을 더하고, Store에 선택 획 제안·확정·취소와 세대 검사를 연결한다. Workspace에 한국어 버튼과 비교 미리보기를 연결한다. NodeTile·PNG renderer는 실제 도형을 그리며 두 pbxproj에 새 소스를 포함한다. 기존 수동 `addNode` 버튼은 새 기능으로 취급하지 않는다. 확정은 기존 저장기가 성공한 뒤에만 메모리 장면을 갱신한다. 원본 `drawingBase64`, 획 ID, 필압, 투영은 유지한다.

`python3 Tests/checks/ink-shape-proposal/run.py /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-completion-20261028/shape-checks`로 실행한다. storage-route가 확인한 외장 경로만 사용한다. 접합 패치를 격리 복사본에 적용해 표준 `PKStroke/PKStrokePath/PKDrawing`, 기존 Store와 JSON 저장기를 실제 실행한다. iOS 27 SDK 전체 Canvas 소스 타입 검사도 수행한다. 결과와 입력 해시는 출력 폴더의 `result.json`, 실행별 로그에 남는다. `--mac-only`는 빠른 수정 확인용이며 전체 SDK 통과가 아니다. UI를 열지 않으므로 시각 수용 증거는 없다.

## 실제 관측과 한계

원앱 근거는 `rea-myscript-diagram-20261023/observed-spec.md`와 `rea-stage1-20261021/coverage-current-index.json`의 MS18이다. 관측된 것은 MyScript Notes 7.5.2의 두 상자·화살촉 없는 선 보정, 연결 추종·끝점 편집, 취소·다시 실행, 저장·재열기다. REA Evidence `ev_0e781f41f936ba62c7b21a079d887fefba0465027046c72c64ddb162ff2b633e` 및 저장본 SHA `3145d69853222c77feb9fa9ee15f3ab03d0481a26730ffa320fbacce3b0619de`를 재사용한다. 원앱을 이번 작업에서 다시 조작하지 않았다.

SDK 공개 PencilKit의 `PKStrokeRecognizer`는 글자 인식·검색 API를 제공한다. 조사한 공개 Swift 인터페이스에 도형 인식 API가 없어 최소 기하 판별을 사용한다. 선택 묶음 하나에서 단일 직선, 단일 또는 연속된 최대 네 획의 축 정렬 사각형, 단일 타원만 제안한다. 타원은 사용자 지정 구현 범위이며 이번 원앱 표본에서 관측됐다는 주장이 아니다. 이 기하는 MyScript의 닫힌 엔진 복각이나 통계적 인식 신뢰도 모델이 아니다. 회전된 사각형·혼합 도형·방향 화살표·문자 배치·복잡한 낙서·새 연결 추종은 지원 범위가 아니다. 거부는 원본을 보존하며 후보도 자동 확정하지 않는다.

원본 필압·마스크의 표현을 재해석하거나 보정 획으로 대체하지 않는다. 마스크 획은 거부한다. PencilKit이 NaN 필압을 공개 readback 전에 유한값으로 정규화하는 동작도 별도 관측했다. 이 경우 정규화 전 값을 읽거나 복구했다고 주장하지 않는다. 손상된 저장 투영의 NaN 필압과 공개 API에서 반환된 비유한 수치·비가역 변환·너무 짧은 획·구별 불가 표본은 거부한다. 샘플·선택 수 상한은 이 좁은 판별기의 입력 계약이다.

도형 종류는 JSON 노드에 저장되며 실제 파일과 새 Store 인스턴스 재열기를 검사한다. 구형 iPad 빌드는 새 종류를 읽지 못하므로 호환 후보 통합 전 배포할 수 없다. 기존 Mermaid/Pele와 relay의 텍스트 투영은 여전히 일반 요소로 표현한다. 도형별 Mermaid 투영·실제 Obsidian 공용 원본 왕복·역방향 수정·연결선 동등성은 이 단위에서 완료되지 않았다. 부모의 공용 저장 writer와 후속 소비자 계약 검수가 필요하다. 사용자 UI·Pencil·기기·Host·네트워크·설치·개인 문서 변경은 없다. 전체 MyScript/MS18 완료로 올리지 않는다.


## 통합 writer의 후속 호환 정책

위 내용은 c03d 원소유 단위의 범위다. 2026-10-29 실제 저장 정본68a에 접합한 후보는 `../ink-glyph-edit/SHAPE-WIRE-CONTRACT.md`를 우선한다. 새 Kind는 wire 변경이며 같은 schema2의 구형68 호환을 보장하지 않는다. 현재 제품은 box 확정과 원본 보존만 허용하고 line/ellipse는 미리보기 뒤 호환 미정으로 명시 거부한다. Files·scene decode·Pele snapshot·relay 송신도 거부한다. paired relay 개선 전 line/ellipse JSON 왕복을 완료로 세지 않는다. 이 폴더의 shape70 검사는 결합 runner `../ink-glyph-edit/product-check.py`로 실제 제품 소스에서 실행했다. 초기 c03d용 integration.py/patch 실행은 역사적 단위 검사이며 최종 접합 소스의 전체 검증으로 쓰지 않는다.
