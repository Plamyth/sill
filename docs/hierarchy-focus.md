# 일반 계층 가지 초점

기준은 `1f59af85dbf2e9450f38164f5c915747b582f0a1`이다. 별도 `hierarchy-focus-product-20261029/source`, branch `codex/ipad-hierarchy-focus-product-20261029`에서 Store/Workspace의 초점 범위만 소유한다. EPUB WT와 Dalton PDF 책갈피/그룹 WT는 수정하지 않는다.

R085 근거는 `rea-stage1-20261021/margin-focus-observed-spec.md`다. MarginNote Mac 4.4.6의 자체 자료에서 선택 부모·자식 초점→상위→전체와 탭 재열기를 관측했다. 원문/관계/미디어는 보존됐고 현재 focus ID와 방문 이력의 저장 시점은 달랐다. 해당 원앱의 내부 flush 함수·시계·iPad 동작을 복원한 것은 아니다.

## 최소 구현 계약

- canonical `CanvasDocument`와 선택 scene은 그대로다. 기존 `parentChild` 링크에서 일시적으로 범위를 계산하며 두 번째 tree나 저장된 scene 사본을 만들지 않는다. 기존 태그/그룹 visibility와 읽기 전용 표시 투영에만 적용한다. 순환·다중 부모·없는 endpoint/root는 추정하지 않는다.
- 현재 root와 페이지별 고유 방문 ID 순서는 기존 `CanvasRuntime.Defaults`의 `canvas.hierarchyFocus.v1` 한 key에 둔다. nil root는 전체 보기다. 모델/문서/packet/서버 스키마는 바꾸지 않는다. 잘못된 설정은 원문·설정을 보존하고 전체 보기와 명시 안내를 남긴다. 정상 앱은 기존 UserDefaults 경로이므로 원앱의 저장 지연/내구성을 동일하게 재현했다고 주장하지 않는다.
- 보기 전환은 원문 revision·graph Undo·Files/Relay checkpoint를 바꾸지 않는다. 원문 저장·AI packet·Document Relay PUT은 전체 원본을 사용한다. 방문 이력은 편집 Undo 항목이나 AI 본문이 아니다.
- 초점 중 자유 Pencil 원본 획은 표시·선택·그리기 입력에서 가리고 전체 보기에서 다시 표시한다. 소유권 추정으로 일부 획을 잘라 내지 않는다. 원본 drawing/strokes·필압·mask·transform은 원문에 그대로 남는다. 보이는 카드의 편집/접기/Undo는 기존 transaction을 사용한다.
- command owner는 문서/page/페이지 epoch·scene generation·selection generation·보기 generation을 결속한다. 기존 그룹 보기 generation을 함께 올려 이전 메뉴/diagram 콜백을 무효화한다. 페이지·부모/자식 ABA에서 같은 UUID가 돌아와도 이전 callback을 수용하지 않는다. 실제 UIKit callback 수용은 별도다.
- 재열기/페이지 이동은 해당 문서+페이지의 root/방문 이력을 복원한다. 사라진 root·순환은 원문/이력을 삭제하지 않고 전체 보기로 돌아간다. 외부 환경설정 값이 바뀌면 기존 값을 조용히 덮지 않고 새 Store에서 재조회하도록 보존한다. 기존 그룹의 collapse/멤버/순서와 원래 카드 ID는 바꾸지 않는다.

## Pstack/Ponytail 실행 경계

Pstack how로 canonical mutation·기존 visibility·그룹/태그·defaults·native callback/문서 install 경계를 대조했고, Ponytail은 기존 환경설정·투영·group view owner를 재사용하는 선택에 적용했다. 부모가 지정한 독립 제품 writer 역할을 유지한다. 이 세션에 spawn_agent가 없으므로 병렬 설계/구현 에이전트를 생성했다고 주장하지 않으며 독립 검수를 자기 검수로 대체하지 않는다. ARENA/순정 Goal/새 DB·서비스·앱/loop/GUI·기기·설치·Host·오디오·키·사용자 질문0이다.

- Blocking first steps: 정확 기준/별도 WT/소유 파일/기존 원본 보존을 확인했다.
- Independent workstreams: EPUB 독립 검수/HTTP·부모 EPUB 수리·Dalton PDF 책갈피는 각각 원담당 WT에서 독립 진행한다.
- Shared mutable state: 이 WT의 Store/Workspace 초점 구간은 이 writer만 쓴다. 공식 integration은 부모가 소유한다.
- Smallest safe decomposition: 기존 투영과 Store 원본/메뉴/콜백을 한 단위로 확인해야 하므로 같은 writer가 최소 접합·native 검사를 수행한다. 독립 소유 모듈이나 새 저장 체계를 추가하지 않는다.

## 검증과 미수용

`Tests/checks/hierarchy-focus/run.py --output <storage-route 외장 경로>`는 실제 Store·PKDrawing·기존 격리 preferences와 전체 Document Files를 사용한다. 새 프로세스 재열기·실제 파일 역수신과 부적합 in-memory 그래프 입력의 범위를 구분한다. SDK는 `--sdk-check` 옵션이다. 실행 input SHA·normal sentinel·commit/tree와 결과는 외장 실행 폴더에만 쓰며 tracked 결과를 갱신하지 않는다. 실제 UIKit/iPad/원앱 수용과 두 앱 전체 완료는 false다. 독립 검수는 남아 있다.

### 실제 native 실행

`evidence/focus-70ea4ae4-8836-4e6c-8e33-51b32dcdb710/result.json`·`observations.json`에 실제 Store/PKDrawing/격리 preferences/전체 Document Files 실행을 보존했다. compile/native exit0, source·normal sentinel 불변이다. 별도 프로세스 재열기는 legacy1회와 전체문서2회이며 총3회다. 원문/주석/교차링크/native ink 보존, AI packet·Document Relay PUT 전체 bytes, 초점 중 편집·Undo/Redo, 부모/자식 및 페이지 ABA, 기존 접기·그룹 진입, 외부 preference 충돌, 실제 Files 수정·루트 삭제 역수신을 확인했다. 순환은 public Store.scene에 주어진 in-memory 원문 입력의 반례이며 손상 외부 Files를 성공 수용했다고 주장하지 않는다.

native Undo는 초점 동안 기존 manager의 명령 진입만 막고 이력을 소비하지 않는 대조를 수행했다. 실제 UIKit/Pencil native Undo 수용은 아니다. 시험 코드 API 이름·초기 schema·그룹 초기 접기 가정 오류와 후속 교정 실행은 각각 실패 영수증으로 보존하며 제품 기능 실패/수리와 섞지 않는다. 통과 뒤 `--sdk-only`로 새 iOS Store/Workspace 입력만 검사할 수 있어 native 재실행이 필요 없다.

### iOS27 SDK

`evidence/focus-1ca0b415-5821-4f9a-85ec-d505f2c8a00d/result.json`에서 정확 제품 commit `c5129946901d50b8d6cd58fdf1bd099a5f33763a` / tree `8ec6716e4f66d135f1f981094542e0957f1efbef`의 plist·iOS StreamProtocol·전체 Store/Workspace typecheck가 모두 exit0이었다. 시작/종료 입력 SHA와 normal sentinel이 같았다. native를 다시 실행하지 않은 `--sdk-only` 결과다. 기존 오디오/UIScreen API deprecation 경고는 수리 범위에 포함하지 않았다. 최종 문서 근거 추가는 제품 bytes를 바꾸지 않는다. SDK 통과는 UIKit/iPad/설치·독립 수용이 아니다.

### 같은 루트로 돌아오는 ABA의 별도 반례

기존58의 child-owner 거부는 자식→부모 전환 경계다. 같은 루트/선택 UUID까지 돌아오는 ABA는 `evidence/focus-1fbf4f76-bbd9-4827-8520-34fa2f8c696e/result.json`·`observations.json`의 별도6조건으로 확인했다. A 초점 owner를 캡처한 뒤 A→B→A를 실행하고, 과거 A owner로 C 초점을 적용하려는 callback을 거부하며 원문/revision도 그대로였다. `--aba-only`는 해당 반례만 실행했고 기존58/child3/SDK를 반복하지 않았다. 제품은 SDK를 통과한 c512 그대로이며 이 후속은 검사·문서만 바꾼다.
