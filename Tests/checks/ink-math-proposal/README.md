# 선택한 수식의 교정·계산 후보 첫 단위

부모 목표/standing과 기존 MS20 행을 그대로 따른다. 부모 파일은 `/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-completion-20261028/GOAL_PROMPT.md`, `preferences.md`, `program/units.tsv`다. 새 전체 조사표·목표·루프는 만들지 않는다. 사용자 최신 지시로 기준은 `68a1b4aaad6faba5a5449d82b81e147479b81930` / tree `d2e14f2df0797a26827a73a6c1d0261614b87dd3`, 브랜치는 `codex/ipad-ink-math-20261029`다.

Pstack의 how → 기존 구조와 소유 범위 확인 → 최소 구현 → 실제 파일/SDK 검증 경로를 사용한다. Ponytail로 기존 PKStrokeRecognizer, PKDrawing/selection, note/sourceStrokeIds, graph Undo/Redo, 저장기와 VaultMarkdownEditor의 Scribble·입력 중 가드를 재사용했다. 기존 Canvas 경로에서 산술 parser를 찾지 못해 Foundation Decimal의 최소 재귀 하강 parser만 추가했다. ARENA·순정 Goal·동적 코드 실행·새 provider/모델/유료 의존성은 없다. 별도 하위 에이전트 도구가 없어 독립 검수는 부모 reviewer가 맡아야 한다.

이 writer의 직접 변경은 새 `CanvasInkMathProposal.swift`와 이 폴더뿐이다. 차단 선행은 정확 기준과 기존 계약 확인이며, 부모의 glyph·shape·relay와 독립인 math 모듈/검사만 진행한다. 공유 Model/Store/Workspace/pbx 파일은 읽기만 하고 접합 diff를 격리 입력에 적용해 검증한다. 최종 제품 접합은 통합 writer 소유다. 필요한 최소 분해는 모듈 하나와 같은 모듈을 구동하는 검사이며, 공유 UI/Host/기기/실제 vault는 점유하지 않는다.

## 제품 흐름과 저장 계약

영역 선택 → ‘선택한 수식 계산’ → 선택한 native 획만 기존 인식기에 전달 → 원본 이미지·인식 원문·교정 편집기·계산 미리보기 비교 → ‘원본을 보존하고 확정’ → 기존 note 하나 추가 → 기존 구조 Undo/Redo 및 저장/재열기다. 인식 nil이면 그 사실을 표시하고, 원본을 보며 직접 교정하는 경로를 제공한다. 교정은 기존 VaultMarkdownEditor의 Apple Pencil/Scribble 및 키보드 입력을 이용한다. 코드·키보드/문자열 주입 검사는 실제 Pencil 센서 수용이 아니다.

확정 전에는 scene에 노드를 넣지 않는다. 명시 확정도 최신 snapshot·selection·scene generation·selection generation·입력 중 상태를 검사하고, 계산 및 기존 persistScene 성공 뒤에만 scene과 graph history를 갱신한다. 저장 실패 시 후보와 초안을 유지한다. 실제 노드는 기존 `kind: note`, `confidence: confirmed`, 원본 `sourceStrokeIds`와 사람이 읽는 ‘인식 후보/수정한 식/계산’ 텍스트를 사용한다. 새 JSON kind나 별도 wire 필드를 추가하지 않는다. drawingBase64·획 필압·mask·transform·다른 노드는 그대로 유지한다. 이 note는 의미 수식 AST나 원앱의 수학 개체 스키마가 아니다.

Module은 `next = scene`에서 note와 revision만 바꾸며 schemaVersion을 2로 설정하지 않는다. 현재 기준 모델은 schema3을 지원하지 않으므로 정상 경로는 원본 버전 그대로 거부한다. `--schema3-probe`는 검사용 격리 Model 복사본의 지원 조건만 3까지 연 다음 같은 제품 모듈/Store에서 확정·Undo/Redo·실제 JSON/새 Store 재열기의 버전3 불변을 확인한다. 이 모의 소비자 검사는 공식 schema3 migration·capability·전체 제품 통합 수용이 아니다. 실제 schema3 소비자는 통합 writer가 그 정확한 계약에서 다시 수용해야 한다.

## 지원하는 계산과 거부

ASCII 숫자, 점 소수, 괄호, 단항 +/-와 기본 + - * /, 명확한 곱셈·나눗셈·빼기 기호 × ÷ −만 지원한다. 끝의 `=` 하나는 계산 요청 표시로 허용한다. `1+1=2`처럼 답을 포함한 등식이나 변수/함수/지수/단위/행렬/분수 표기/모호한 O·l·z/쉼표 소수/전각 숫자는 거부한다. O를 0으로 추측하지 않는다.

식 UTF-8은 256바이트, 숫자 literal은 28자리, 재귀 깊이는 16 미만이다. 나눗셈은 양쪽 십진 계수가 각18자리 이내인 입력에 한정하고, 정수 최대공약수로 약분한 분모의 소인수가 2·5뿐인지 먼저 검사한다. `1/3` 같은 무한소수는 근삿값을 조용히 확정하지 않고 명시 거부한다. Foundation 나눗셈이 1/3을 오류 코드 없이 반올림한 실제 검사 결과 때문에 이 검사를 추가했다. Decimal이 보고하는 정밀도 손실·overflow/underflow와 0 나눗셈도 거부한다. 이는 제한된 십진 산술이며 임의 정밀도 수학 엔진이 아니다.

## REA 근거와 실제 한계

`rea-stage1-20261021/coverage-current-index.json` MS20의 링크인 `ipad-native-feature-survey-20261022/myscript-math-observed-spec.md`를 재사용했다. 원앱에서 실제 Pencil `1+1=` 입력, 후속 일반 터치 변환의 결과2, 저장/재열기는 관측됐다. 저장본 SHA는 `11a84d3a836b2780fc64dddffea9eac3fe1457db605f8c7cf664899c5de48abd`, REA ZIP Evidence는 `ev_a25f2834343f607ee2cc444231ddcea061d9756932a89cc2e1de79f543bf462a`다. Pencil로 바꾼 2가 z로 오인식되어 `1+z=?`가 된 후속은 성공 재계산이 아니다. 해당 실패 저장 Evidence는 `ev_c5ff8b3f4915dc816f5a4bc0ddeff767224a8156612410cc35ee50220abedbf1`다.

자동검사의 native fixture는 기존 SelectedInkChecks의 자체 표준 PKStroke 기하를 재사용한다. 실제 PKStrokeRecognizer 호출 결과와 주입한 `1+z=`·교정 `1+2`의 성공을 별도로 기록한다. native ownfixture는 이번에도 nil이며 실제 손글씨 수학 인식 성공이 아니다. nil 후 직접 교정은 사용 가능한 제품 경로다. 원앱 전용 수학 인식기·글자별 수식 센서 교정·고급 수학·실제 Pencil 수용·실제 vault 왕복·설치·전체 MS20/MyScript 엔진 완료는 미완료다.

## 검사와 접합

`python3 Tests/checks/ink-math-proposal/run.py /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-completion-20261028/math-checks`로 실행한다. 접합 패치는 같은 폴더 `integration.patch`이며 `git apply --check --whitespace=error`로 확인 후 통합 writer가 소비한다. Model은 직접 변경하거나 patch하지 않는다. Store, Workspace, 제품/진단 pbx의 접합과 실제 Scribble 편집기 호출은 iOS27 SDK 전체 Canvas 타입 검사로 확인한다. 실행 결과는 출력 폴더의 result.json과 runtime.log에 남는다.

`--schema3-probe --mac-only`는 별도 출력 폴더 `math-schema3-checks`에서 실행한다. 이 옵션의 지원 Model 변경은 검사 복사본 안에만 존재하며 최종 접합 패치에 들어가지 않는다. 일반 검사와 모의 schema3 결과를 합쳐 공식 지원으로 표시하지 않는다. 모든 시험은 격리 홈과 자체 파일에서 진행한다. 개인 원본·기기 UI·Host·네트워크·계정/키·설치·개별 Pencil 요청은 0이다.


## 8509 기반 실제 제품 접합

통합 writer는 clean `8509e3c8a4abe9c1ad4ceabe26aae40ca02a22e1`에서 정확한 원소유 `40f9841141359a617ea47796d4e0812686f61802` / tree `39b12ed639742d7451bb392b36a7686432839c56`을 검토하고 `962e0ab`로 cherry-pick했다. 이 writer는 같은 glyph-integration-source에서 Store/Workspace/정상 iPad·iPhone 및 진단 pbx에 직접 접합했다. 기존 glyph·shape와 scene3, relay capability 정책을 유지하며 relay import·서버 변경은 하지 않았다.

최초 원소유 integration.patch/integration.py는68a 대상의 과거 접합 근거로 보존한다. 실제 최종 접합은 product-integration.patch다. 수식 proposal은 scene 전체/native 바이트/선택 ID를 동결하고, Store의 scene·selection 세대와 요청 토큰으로 늦은 callback/ABA를 차단한다. 모드·선택·drawing 변경 및 실제 Pencil trace의 상태 전환도 무효화한다. math 입력 중 glyph/shape 동작은 초안을 버리지 않는다. 수식 제안 시작 시 과거 glyph/shape 후보를 무효화한다. 저장·원본 차단·Vault 입력/저장 상태의 보호를 기존 경로와 맞췄다. 확정은 native 획을 교체하지 않고 note를 추가하며 복구본 반영과 Files 미저장·Obsidian 동기화 대기를 명시한다.

`run-product.py --output <storage-route가 허용한 외장 폴더>`는 실제 제품 Model/Store/glyph/shape/math를 직접 컴파일하고 원소유 main의 제품 접합 부분만 실행한다. 소스 위치는 내부/외장 모두 허용하며 새 홈·tmp·로그·실행·영수증은 외장 출력에만 둔다. 원소유 math-checks/result.json과 runtime.log의71검사·native nil 및 parser 결과를 재사용한다. 실제 인식기를 재호출하지 않고 인식 문자열/nil을 명시 주입한다. scene3은 모의 Model 사본이 아니라 현재 제품 모델에서 파일 저장·새 Store 재열기·Undo/Redo로 검증한다. raw ink/mask/필압/transform/주변 요소, 늦은 callback, 입력 보호, 실제 cache 및 Files IO 실패와 CAS 외부 원본 보존을 대조한다.

개발 중 Files 실패 뒤 단순 save를 호출한 검사는 기존 blocked 보호에 막혔다. 보호를 완화하지 않고 제품의 명시 retryFileWorkspaceSave 경로로 고친 뒤 재검증한다. 실패 로그는 외장 실행 폴더에 보존한다. cache 오류 검사는 손상된 Store에서 새 proposal을 시작시키는 과거 방식 대신, 유효한 preview 뒤 자체 지원 폴더의 쓰기 실패를 만들어 후보·초안·원본 보존을 확인한다.

최종 actual-product glyph 정책/전체 Canvas iOS27 SDK, shape·Files 필수 회귀 및 정상 bundle 무서명 전체 빌드는 기존 외장 실행기를 사용한다. native/계산 모듈 성공을 실제 수식 손글씨 인식·UI/Scribble/Pencil·고급 수학·원앱 전체 동등성으로 세지 않는다. 수용은 부모의 새 후보 독립 검수 전이다. 이번 UI 실행·기기·Host·새 원앱 조사·Pencil 요청·설치·push는0이다.
