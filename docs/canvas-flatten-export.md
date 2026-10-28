# 공유용 PNG·PDF 내보내기

원앱 MarginNote iPad의 MI31.01 Flatten PDF 동작 근거를 CCR Sill의 기존 그림판에 연결한다. 현재 장면을 복사해 기존 SceneRenderer가 만드는 이미지와 같은 내용을 PNG 또는 한 장 PDF로 Files에 저장한다. 원본 JSON 내보내기는 유지한다. PDF는 이미지이며 편집 가능한 글자·잉크·원문 앵커를 담았다고 표시하지 않는다.

원본 장면·Obsidian 노트·사용자가 선택한 공용 작업 폴더와 동기화 상태는 바꾸지 않는다. 이미지를 만드는 동안 장면 바이트가 바뀌면 이전 이미지 내보내기를 취소한다. 화면 이탈·비활성화로 취소된 준비의 늦은 결과도 적용하지 않는다. 파일명은 장면 ID·revision을 포함한다. 파일 대화상자는 Apple의 기존 fileExporter를 재사용한다. 새 앱·권한·DB·네트워크·외부 전송은 없다. 렌더링 실패와 파일 선택 취소는 원본에 영향을 주지 않는다.

PNG/PDF는 공유용 파생 파일이며 편집 원본의 별도 보관 완료를 대신하지 않는다. 기존 scene JSON·native drawing과 원본 파일 저장 계약은 그대로다. 큰 장면은 이미지를 만들기 전 최대32M 픽셀을 확인하고 초과하면 JSON 원본 경로를 안내한다. 자동 검사와 실제 iPad fileExporter/SceneRenderer·Pencil 수용은 구분한다.

`Tests/checks/canvas-flatten-export/run.py <외장 증거 경로>`는 실제 CoreGraphics·ImageIO·PDFKit으로 제품 FileDocument 선언을 검사한다. PNG 바이트 보존, PDF 페이지 크기·방향·색상, 실제 파일 저장·재열기, 손상 이미지·잘못된 크기 거부를 확인한다. Mac의 이 검사는 iPad의 전체 화면 렌더링이나 최종 파일 선택을 대신하지 않는다.

내보내기 준비 전·비동기 렌더 완료 후·실제 파일창 표시 binding에서 기존 편집창의 표시 상태를 검사한다. Obsidian·댓글·연결·검색·파일 선택이나 다른 Canvas 편집창이 열리면 준비 token을 취소하고 늦은 이미지를 표시하지 않는다. 이 수정은 통합 검수에서 확인한 표시 소유권 누락을 닫으며, 기존 da5 소스 판정과73번 미설치 후보는 이전 이력으로 보존한다.
