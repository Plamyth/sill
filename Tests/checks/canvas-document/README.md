# 복수 페이지 문서 네이티브 검사

승인된 외장 출력 디렉터리를 `--output`으로 지정한다.

```sh
python3 Tests/checks/canvas-document/run.py --output /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-completion-20261028/canvas-document-evidence --sdk-check
```

실제 제품 CanvasModel과 새 CanvasDocument/CanvasDocumentFiles를 직접 컴파일한다. 실제 PKDrawing/로컬 Files 검사, pbxproj 구문 검사, iOS27 문서 단위 타입 검사다. 전체 앱 SDK/빌드·Store/UI·relay·설치·실기기 수용은 아니다. 출력 영수증은 입력 SHA를 전후 대조한다. 정상 동작과 실제 IO 실패 검사를 실패 hook을 주입한 검사와 로그에서 구분한다. 정상 앱의 사용자 자료를 읽거나 쓰지 않는다.

계약과 남은 접합은 `docs/canvas-document-v1.md`에 있다. 실행 결과를 tracked 파일로 저장하지 않는다.
