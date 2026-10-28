# 원본 잉크 두 그룹의 간격 편집 첫 단위

부모 GOAL_PROMPT.md와 preferences.md 및 기존 원장을 유지한다. 사용자 최신 기준은 `8509e3c8a4abe9c1ad4ceabe26aae40ca02a22e1` / tree `5114594a18aa8060cd9a98433ce3b4fc17dc32e6`이다. 저장 위치는 storage-route가 확인한 `/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-completion-20261028/ink-spacing-source`, 브랜치는 `codex/ipad-ink-spacing-20261029`다. 기존 shape/math/활성 glyph 작업을 수정하거나 따라가지 않는다.

Pstack의 how→계약/소유 확인→원본 이동 구현→실제 native/파일/SDK 검증 경로를 적용한다. Ponytail로 CanvasInkTextEditing.Snapshot/Evidence/nativeEvidence/History/encode와 기존 Store의 native 설치·저장기를 재사용한다. 새 parser·엔진·의존성·모델·wire kind는 없다. ARENA·순정 Goal·반복 모델 실행은 없다. 이 모듈/검사는 독립 작업이며 공유 파일·제품 통합·설치는 통합 writer 소유다. 별도 subagent 도구가 없어 독립 검수는 부모 reviewer가 해야 한다. 새 전체 계획/조사표를 만들지 않는다.

## 정확히 지원하는 입력

기존 note 하나가 선택한 native 획 전체를 sourceStrokeIds로 참조해야 한다. 사용자가 왼쪽/오른쪽 문자 또는 공백 없는 단어와 **정수 1~512포인트**를 명시한다. UI와 propose 모두 소수·비유한 값·범위 밖 입력을 거부한다. 기존 이동 검사는 정수 거리20/10포인트를 사용했다. native 직렬화 뒤 요청 affine를 정확히 유지하지 못하는 경우도 적용하지 않으며 필압·ID·다른 획 보존 검사를 완화하지 않는다. split은 기존 문구가 두 그룹을 붙인 문자열일 때만 오른쪽 그룹을 +x로 해당 거리만큼 이동하고 ASCII 공백 하나를 넣는다. join은 기존 문구가 두 그룹 사이에 공백 하나인 경우, 두 그룹 사이 확인한 빈 간격보다 작은 양만큼 오른쪽을 -x로 이동하고 그 공백 하나를 제거한다. 단순 UITextView 공백 편집으로 완료하지 않는다.

두 그룹마다 기존 nativeEvidence를 호출한다. wholeText가 기존 note 원문과 UTF-8까지 같고, targetText/remainingText가 양쪽 입력과 각각 일치하며, 검색 결과가 각각 단 하나의 비어 있지 않은 strokeID 집합이어야 한다. 양쪽 집합이 서로 겹치지 않고 선택 전체를 정확히 덮고 서로의 otherCharacterMatches도 같은 유일 집합이어야 한다. native 대응이 없으면 거부한다. bbox로 문자를 추측하지 않는다.

bbox는 **대응 확인 후** 그룹의 좌우 순서·한 줄 정렬·겹침·합칠 수 있는 실제 빈 간격을 거부하는 안전 조건에만 쓴다. 회전 note, rotation/shear/reflection/nonuniform transform, 두 줄·대각 배치·겹침은 지원하지 않는다. native path에 직접 그려진 모든 회전을 인식하는 baseline 엔진은 없으므로 이 조건을 일반적인 필기 방향 추정이라고 부르지 않는다. mask가 있는 선택 그룹이나 다른 노드가 선택 획을 공유하는 경우도 거부한다. 무선택/여러 note/부분 선택/유일하지 않은 검색/공유 glyph 획/미확인 문자도 원본을 보존한다.

## 원본과 변환 계약

원래 sceneID/revision/scene SHA/native drawing SHA/nodeID/selection/text/UTF-16 경계는 기존 Snapshot에 보관한다. 정확한 좌우 ID 집합과 before/after scene은 Proposal에, 적용/Undo/Redo의 before/after/expected는 기존 History에 보관한다. 이것은 메모리 제안/이력이다. 앱 재실행 뒤 Undo 이력을 영속 복원하는 기능은 이 단위에 없다. Files 세대 저장은 기존 저장 writer 계약이다.

오른쪽에만 기존 affine transform 뒤의 world translation을 합성한다. original path·필압·크기·opacity·시간·ink·seed·render group/state와 ID를 검사하고, 다른 획의 기존 native 투영 및 mask 가시성/좌표를 대조한다. 선택한 mask 자체는 이동하지 않는다. 다른 노드/관계와 sourceStrokeIds 순서는 바꾸지 않는다. 오른쪽 transform의 이동 성분은 의도적으로 바뀌며 이전 transform과 전체 native 바이트는 before/Undo에 남는다. schema는 max(2,기존값)이므로3을 낮추지 않는다.

실제 SDK 표본에서 PKDrawing.transformed와 stroke.transform setter 모두 stroke ID를 보존했다. 이 구현은 후자를 쓰고 serialize/readback 뒤 모든 ID/순서가 같지 않으면 명시 거부한다. 임의 새 ID 매핑은 하지 않는다. 같은 stroke에서 각각 만든 두 PKDrawing은 ==false였으므로 다른 획의 보존 판정에 그 컨테이너 비교를 사용하지 않는다. TransformAudit.swift는 이 관측을 별도로 재현한다.

## 제품 접합

integration.patch는 Store의 기존 입력/Files/보관함 보호, scene·selection·mode·Pencil ABA 취소와 취소된 작업 처리에 연결한다. 기존 nativeEvidence와 유일 note target을 사용한다. 명시 확정·Undo/Redo 모두 기존 persistScene 성공 뒤에만 native scene을 설치한다. 실패하면 후보/원본/이력 단계는 유지한다. Files 원본과 Obsidian 저장 성공으로 과장하지 않고 복구본 반영·외부 동기화 대기를 표시한다.

Workspace의 ‘원본 획 간격’ 버튼에서 두 그룹·거리·동작을 입력하고 동일한 공통 bounds의 before/after native 이미지를 비교한 뒤 확정한다. 글자별 Scribble 제스처를 복제한 것이 아니라 명시적 간격 제안 UI다. 두 pbx에 새 소스만 추가한다. Model/Store/Workspace/pbx의 live 파일은 수정하지 않는다. 부모 writer가 patch를 대조·통합해야 하며 여기서는 push·병합·설치하지 않는다.

## 검사와 남은 범위

86f425 후속 반례는 `boundary-check.py OUT --baseline`으로 고정 Git 객체의 두 경우만 한 번 관측했다. 정상 native 자료에서 schemaVersion만99로 바꾸면 기존 validateNativeInkProjection→hasSupportedInkProjection이 native 검색 전에 명시 거부했고 장면/원본 바이트는 그대로였다. 따라서 별도 schema validator나 중복 호환 검사를 추가하지 않았다. amount1.1은 두 그룹 대응 후 identity 거부였고 native 직렬화에서 transform.tx가1.1→1.100000023841858로 바뀌었다. 이 단위는 소수 정규화/허용오차 수용을 추가하지 않고 정수만 지원한다.

`python3 Tests/checks/ink-spacing/boundary-check.py OUT`은 수정 뒤1.1이 검색 전에 구체적인 정수 입력 오류로 거부되는지, 정수20의 native 직렬화 이동·schema3·source IDs·필압·다른 획·원본 보존을 검사하고 변경 모듈만 iOS27 SDK로 검사한다. 기존40개 검사와 전체 SDK 검사는 반복하지 않는다. integration.patch 및 Model/Store/Workspace/pbx는 이 후속에서 바꾸지 않는다. 두 명령의 OUT은 storage-route가 확인한 외장 development-archive 아래여야 한다.

`python3 Tests/checks/ink-spacing/run.py /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-completion-20261028/ink-spacing-checks`로 실행한다. 테스트 입력은 격리 복사본에 패치를 적용한다. SDK의 native stroke를 사용하지만 글자 검색 대응은 주입 정책 검사와 실제 nativeEvidence 호출을 분리한다. 이번 실제 호출은 두 그룹 대응을 확정하지 못해 거부됐고, 성공한 간격 제안·적용 검사는 증거 주입 정책 검사다. 기존 자체 선형 fixture의 native 검색/인식은 실제 문자 간격 편집 성공 증거가 아니다. 실제 Pencil 센서·UI·Host·개인 vault·네트워크·계정/키·설치는0이다.

기존 원앱 근거 `myscript-pencil-gesture-stage-20261021/myscript-pencil-delete-join-split-audit-acceptance.json`은 실제 Pencil 삭제·합치기·나누기의 좁은 화면/작업 파일 관측이며 finalSaveReopenAccepted=false, productImplemented=false를 유지한다. 이 구현을 원앱1:1 동등성·전체 MyScript 간격 엔진 완료로 올리지 않는다. native 대응을 얻은 실제 필기, 일반 문장 내 임의 경계·여러 줄·회전·부분 mask·조합형/shared stroke의 이동·자동 baseline·재실행 Undo 및 실제 Files/Obsidian 왕복 수용은 미지원 또는 미검증이다.
