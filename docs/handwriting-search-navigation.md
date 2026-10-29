# 현재 페이지 손글씨 검색 결과 위치 이동

기준은 `c8992bbec29297148eb5a4b69b072fb3d579cdbf` / tree `b61c8345664b2b2bf96f8b37d6930a7a3ac98588`이다. 별도 `codex/ipad-handwriting-search-navigation-20261029` WT에서 현재 페이지 native 필기 검색의 첫 유효 결과를 원본 그림 화면에 가져오는 행동만 추가한다.

## 기존 계약과 변경

`CanvasViewport`는 기존 Store의 임시 zoom/pan이며 Codable scene/document·원문/Files·preferences의 저장 필드가 아니다. 이번에도 viewport를 영속 저장하지 않는다. `searchHandwriting`은 현재 PKDrawing을 기존 PKStrokeRecognizer로 검색하고 유효한 stroke UUID 결과를 lasso로 선택한다. 새 검색 엔진·인덱스·DB·wire·다른 페이지 검색은 없다.

기존 GeometryReader에서 원본/나란히 보기의 실제 그림 영역 크기를 전달한다. inactive·다이어그램 전용·다른 sheet 소유·뷰 제거·0/비정상 크기는 표시 불가로 다루고 검색 이동 성공을 만들지 않는다. 검색 alert 자체의 입력을 닫는 경로는 유지한다. 실제 geometry/SwiftUI event 순서와 물리 화면은 SDK/native 검사만으로 수용하지 않는다.

유효 stroke 결과의 첫 집합으로 PKDrawing bounds를 구하고 페이지 안 영역을 현재 배율로 가져온다. 이미 여백 안에 보이면 viewport를 바꾸지 않는다. 화면보다 큰 결과는 zoom을 유지하고 페이지 안 bounds 중심을 표시한다. 전체 결과가 화면에 다 들어온다는 뜻이 아니다. 첫 결과가 페이지 안에 표시할 영역이 없으면 원본/선택/보기를 그대로 유지하고 실패 안내를 남긴다. 결과의 정렬·순위 의미는 해석하지 않으며 recognizer가 반환한 첫 유효 집합을 사용한다.

원본 glyph/ink·pressure/mask/transform·노드/링크/주석·ID·revision·graph/native Undo를 검색의 보기 전환으로 바꾸지 않는다. 기존 전체 일치 획 선택과 개수 표시는 유지한다. 소스 전체 바이트 불변은 구현 의도만으로 단정하지 않고 실제 native/복구 파일/전체 Document Files 전후 대조로 한정한다.

## 요청 소유와 취소

기존 document pageSnapshot와 request UUID 검사는 유지한다. pan/zoom·화면 크기/가시성 변경은 검색 요청만 취소한다. A→B→A로 값이 돌아와도 한 번 무효화된 UUID를 재사용하지 않는다. 별도 글자 인식 요청을 보기 변경만으로 취소하지 않는다. 새 검색은 기존처럼 이전 검색/인식 요청을 대체한다. Task 취소·새 빈 질의·명시 취소·오래된 오류도 새 상태를 덮지 않는다.

검색 중에는 기존 문서 페이지 전환 장벽이 유지된다. 화면 소유 반납/취소 뒤 실제 페이지를 바꾸고 돌아온 상황에서는 과거 검색을 적용하지 않는다. 부모의 초점·목록·Cloze와 의미 통합은 이 브랜치가 담당하지 않는다. 특히 초점으로 원본 native ink를 숨기는 후속 소스와 합칠 때는 그 가시성 조건을 부모가 추가 대조해야 한다.

## 검사와 한계

`Tests/checks/handwriting-search-navigation/run.py --output <storage-route 외장 scoped 경로>`는 실제 Store·PKDrawing·원본 Files와 주입 검색 결과를 사용한다. 순수 viewport geometry, 화면 밖/확대/큰 결과, 한글·결합문자, 빈/무결과·오류·취소, 소스/페이지/보기 ABA, 원본/Undo/Files 세대 보존을 검사한다. 기존 검색 관련 검사만 재사용하고 제품 전체·기존 다른 기능 전체 검사는 반복하지 않는다. `--sdk-only`는 최종 iOS27 plist·StreamProtocol·전체 CanvasBridge typecheck만 수행한다.

주입 검색은 실제 한글 native recognition·sensor·렌더 픽셀 수용이 아니다. 실제 UIKit·Pencil·기기·설치·Host·정상 runtime·HTTP·키/권한·질문·알림·루프를 실행하지 않는다. 원앱 R130/R131의 alpha 1/1 위치 이동이라는 좁은 행동에 대응하며, R092의 EPUB 문서/스터디셋 본문 검색·장 이동 전체를 닫지 않는다.

Pstack how/architect/Feature로 저장·소유·geometry 경계를 대조하고 Ponytail은 기존 recognizer/bounds/viewport를 재사용했다. spawn_agent 도구가 없어 직접 구현했으며 독립 SOURCE_CLEAR는 부모의 비저자 검수에 남긴다. ARENA·순정 Goal·push·공식 integration 변경은 없다.
