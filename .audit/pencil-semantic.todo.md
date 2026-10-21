# Pencil 의미 편집 구현

Pstack Feature가 범위·검증·통합을 관리하고 Ponytail은 기존 UITextView·Store·relay를 재사용하는 구현에 적용한다. ARENA는 사용자 금지로 실행하지 않는다.

- [x] 기존 인식 텍스트 편집·동기화 흐름과 실제 REA 삭제/합치기/나누기 근거 확인.
- [x] 원격 integration db6eb823 확인, 소유 작업 브랜치·워크트리 생성.
- [x] Blocking first steps. 기존 사용자 앱/원본 보존과 소유 device lease, 격리 보관함 먼저 준비.
- [x] Independent workstreams. 순수 모델 구현과 UIKit 연결을 분리했고 독립 검수는 읽기 전용으로 실행.
- [x] Shared mutable state. 현재 UIKit·기기 쓰기는 부모 하나만 담당. worker 소스 작성 종료 뒤 빌드. 첫 동시 소스 변경으로 멈춘 빌드는 실패로 보존.
- [x] Smallest safe decomposition. 모델1개와 기존 편집기 연결. 새 동기화·상위 작업 관리 계층 없음.
- [x] 순수 모델253검사와 SDK 타입 검사 통과.
- [x] 독립 검수의 다중 행 삭제 P2 수정 및 재검수0건.
- [ ] 실제 UIKit 글자 범위·삭제·합치기·나누기·Undo/Redo·저장 재열기 통과.
- [ ] 격리 Obsidian JSON/Markdown/PNG readback과 Mac→iPad 역방향 확인.
- [ ] 검수한 소스 커밋을 단일 integration에 수렴하고 정확한 소스로 재검증.
- [ ] 정상 CCR 앱 반영과 실제 Pencil 센서 수용. 합성 trace와 구분하고 사람 항목만 공식 DIS로 전달.

초기 geometry 검사 획이 이웃 글자까지 덮은 결과를 성공으로 바꾸지 않았다. 실제 글자 폭으로 입력을 좁히고 대상 범위 자체를 추가 단언한다. native Goal·별도 heartbeat는 만들지 않는다.
