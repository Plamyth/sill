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
