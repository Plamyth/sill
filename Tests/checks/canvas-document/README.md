# 복수 페이지 문서 네이티브 검사

승인된 외장 출력 디렉터리를 `--output`으로 지정한다.

```sh
python3 Tests/checks/canvas-document/run.py --output /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-completion-20261028/canvas-document-evidence --sdk-check
```

실제 제품 CanvasModel과 새 CanvasDocument/CanvasDocumentFiles를 직접 컴파일한다. 실제 PKDrawing/로컬 Files 검사, pbxproj 구문 검사, iOS27 문서 단위 타입 검사다. 전체 앱 SDK/빌드·Store/UI·relay·설치·실기기 수용은 아니다. 출력 영수증은 입력 SHA를 전후 대조한다. 정상 동작과 실제 IO 실패 검사를 실패 hook을 주입한 검사와 로그에서 구분한다. 정상 앱의 사용자 자료를 읽거나 쓰지 않는다.

계약과 남은 접합은 `docs/canvas-document-v1.md`에 있다. 실행 결과를 tracked 파일로 저장하지 않는다.

DOC-R1/R2/R3 수리는 다음 선택 인자로 reviewer가 보존한 세 미지원 JSON 원문과 과거 관측을 직접 대조한다. 검수 폴더는 읽기 전용 입력이며 출력·프로세스·새 fixture는 `--output` 안에만 둔다.

```sh
python3 Tests/checks/canvas-document/run.py --repairs /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-completion-20261028/canvas-document-independent-review-0fd008a --sdk-check --output /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-completion-20261028/canvas-document-evidence
```

`regression.swift`는 정본 디렉터리 교체 후 폴더 수준 barrier·원본/외부/제안 전체 보존, nested 원문 거부, 실제 별도 프로세스의 LOCK_EX 경합 중 즉시 busy 반환과 해제 후 정상 저장을 확인한다. 디렉터리 교체는 명시 hook에서 실제 파일 rename을 수행한다. lock은 주입 evidence가 아니라 자체 두 프로세스의 실제 flock이며 앱 UI는 실행하지 않는다.

Files 저장 재사용은 `--storage-reuse`를 추가해 같은 입력/workload를 exact782 baseline 및 새 소스에 각각 실행한다. 실제 파일 내용 바이트·regular 경로·디렉터리 포함 전체 경로를 측정하며 물리 APFS 할당으로 확대하지 않는다.

```sh
python3 Tests/checks/canvas-document/run.py --storage-reuse --repairs /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-completion-20261028/canvas-document-independent-review-0fd008a --sdk-check --output /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-completion-20261028/canvas-document-storage-evidence
```

`storage.swift`는 no-op의 새 경로/바이트 0, 정상 base 복사 생략, typed owner/UUID/형식, v1 committed 호환과 독립 복구, preview/현재 페이지 변경 저장, legacy/외부 fallback, 손상·참조 교체·미확인 barrier 유지까지 확인한다. no-op이 생긴 뒤 기존 main.swift의 마지막 교환 경합 fixture는 실제 내용이 다른 proposal을 저장하도록 바꿨다. 이전처럼 동일 문서를 저장하면 새 no-op이 정당하게 교환 hook에 진입하지 않기 때문이다. 교환 반례 자체를 생략하지 않고 별도 no-op identity 반례도 유지한다.

실제 단일 Document Store/UI 접합은 같은 실행기의 `--store` 모드로 검사한다. `--repairs`/`--storage-reuse`와는 별도 실행이다.

```sh
python3 Tests/checks/canvas-document/run.py --store --sdk-check --output /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-completion-20261028/canvas-document-product-evidence
```

실제 Store/PKDrawing/native Files/페이지별 UndoManager와 새 프로세스 재열기를 실행한다. URLSession 프로토콜 fixture는 실제 서버 HTTP가 아니다. 렌더 preview는 자체 PNG fixture이며 Pencil 인식·GUI·설치 수용은 아니다. 정상 앱 위치의 sentinel은 전후 대조하고 tracked 결과를 갱신하지 않는다. 자세한 소유·복구·wire 경계는 `docs/canvas-document-store-integration.md`를 따른다.

DOC-STORE-R1 수리는 `--store-r1 --store-r1-review <검수 폴더>`로 같은 실행기를 사용한다. reviewer의 `Cases-v2.swift`는 읽기 전용으로 직접 컴파일하고 `dirty-open`만 실행해 과거 유실 관측과 대조한다. NFC/NFD 가설은 비재현으로 종결됐으므로 재실행하지 않는다.

```sh
python3 Tests/checks/canvas-document/run.py --store-r1 --store-r1-review /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/document-store-independent-review-d24c60f/followup-ohm --sdk-check --output /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/document-store-r1-repair-20261029/evidence
```

`transition.swift`는 바인딩된 미저장/정상 문서, 바인딩 없음, 외부 CAS 충돌, 실제 디렉터리 읽기 권한 실패, renderer 대기 중 취소, 대상 읽기 실패, JSON/legacy 전환을 별도 isolated context로 실행한다. 실패 때 원본·선택·native/graph Undo를 검사하고 새 프로세스에서는 실제 app cache/Files만 읽어 전체 문서와 현재 페이지를 재열어 확인한다. 비교용 expected.json·reviewer의 dirty-before.json은 제품 복구 자료로 주입하지 않으며 보존 성공에 세지 않는다. 성공한 다른 문서 열기 뒤에는 이전 Files 원본이 미저장 본문과 전 페이지를 정확히 유지해야 한다.
