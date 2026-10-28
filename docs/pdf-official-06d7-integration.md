# 공식06d7와 PDF51b의 의미 통합

기준은 공식 `06d7e6d50804e7c8d90551275891df76e2e544cf` / tree `99ab9bc9ccc23544cfc7aa073c9dfcd9c8d77cdf`와 PDF `51b736b736a4d0e1f8bebf4d8870f83fa74ef74f` / tree `a8ed11d5076b36018e5f934ac679e309fbb5af10`다. 전용 PDF 브랜치에 공식만 병합한다. 미완성 일반 노트 UI나 별도 서버 후보를 병합하지 않는다.

## 충돌과 해결

유일한 텍스트 충돌은 CanvasRelay.response다. PDF의 `maxBytes`는 body를 축적하기 전 선언 길이와 각 stream byte를 제한하며 기존 PDF 오류를 반환한다. 공식 `maximumBytes`는 충돌 조회의 기존 수신 후 상한과 URLError를 유지한다. 두 선택 매개변수를 보존해 각 호출의 기존 동작을 그대로 유지했다. typed409 분류와 private 경로 비노출, 공식 conflict API 검증은 바꾸지 않는다.

자동 병합된 CanvasRuntime에는 PDF StateFile/override와 공식 ConflictRecovery의 정확한 이름·현재 runtime UUID 제한이 함께 있다. adapter normal snapshot은 PDF journal과 ConflictRecovery 전체 디렉터리의 합집합이다. LC_UUID와 파일 SHA 결속, glyph/shape/math/spacing 구현 및 공식 서버 전체는 바이트 비교로 보존한다. 프로젝트의 양 target에 PDF 두 파일과 공식 spacing 파일이 함께 등록된다.

## 결합부 보호 수리

공식 canApplyReconciledCanvas는 PDF 원장을 알지 못했다. 보존 중이거나 손상돼 읽을 수 없는 PDF 원장이 있으면 기존 조건에 더해 Canvas 장면 교체를 거부한다. 정상 PDF 저장·동일 경로 결과 확인·scene 카드 연결 뒤 원장이 비워진 경우에만 원래 조정 자격으로 돌아간다. 원장·입력·노트ID·문단ID를 바꾸거나 기존 guard를 풀지 않는다.

## 검증과 범위

기존 actual Store 격리 PDF 검사에 Canvas apply 거부, 장면/PDF 원장 불변, 별도 conflict choice 불변, 정상 확정 뒤 자격 복원, 손상 PDF 원장 보호를 추가한다. normal fixture에는 ConflictRecovery의 choice/local/attempt를 함께 넣는다. 기존 PDF 전송 검사에는 공식 충돌 응답 상한과 typed409 GET 보호를 추가한다. 기존 reconciliation 68건, DEBUG/Release 복구 경로 검사, snapshot 검사 및 결합 제품의 iOS SDK typecheck를 실행한다. 기존385/43 전체 검사는 재실행하지 않는다.

실제 검사 결과와 정확 source hash는 전용 evidence/official-06d7-merge/에 기록한다. 기기/렌더링/설치/Host/오디오/실사용 vault/공유 런타임 수용은 이 검사에 포함되지 않는다. 부모가 공식 반영과 해당 경계를 담당한다.

## 서버 별도 소유

Galileo의 PDF 서버 후보는 `6475df0d9948f6b40d03ee3fe56ec27b638804ed` / tree `28c05e79616d31c9fe55ba884335e2b89c1f4c62`이며 이 병합에는 없다. 일반 노트 resolver 보존 위에 의미 적용한 별도 서버 제품 2파일과 독립 검수 영수증은 부모가 별도로 소비한다. 옛2c90 패치 문서는 역사적 기준이며 현재 공식 적용 가능성을 주장하지 않는다.

## 최종 공식 기준 갱신: 7fa8da53

사용자가 일반 노트 client2abd98d의 SOURCE_CLEAR/actualHTTP 검수와 공식 통합을 확인해 최종 기준을 `7fa8da53eecffd3cf7c97bbe64319ebb021894ed` / tree `429a3e525a213eb50c5c5c72afb75ad786b729c4`로 갱신했다. 이 기준에는 검수 완료한 일반 노트 복구가 있으므로 중간 ea7dfc4 위에 추가 병합한다.

텍스트 충돌은 Store의 canApplyReconciledCanvas와 Workspace의 보관함 toolbar/alert다. guard는 일반 노트 held와 PDF pending/unreadable을 모두 포함한다. 자료 비교 중에는 목록·PDF 닫기 동작을 숨기고, PDF 및 일반 노트 확인 alert를 각각 유지한다. 기존 단일 보관함 sheet에 비교 panel을 표시하고 새 sheet를 추가하지 않는다. 일반 노트 자료 비교 중 PDF 열기, PDF 읽기 중 일반 노트 비교를 시작하지 않는다.

Store의 일반 노트 archive에는 PDF 생성 원장이 포함되지 않으므로 PDF 생성이 pending/unreadable이면 일반 노트 capture/install을 시작하지 않는다. 반대 방향으로도 일반 노트 held일 때 PDF 준비/저장·결과확인 및 stale PDF 필드 편집을 막는다. await 뒤에도 held를 다시 확인한다. 어느 복구 원장을 다른 흐름이 자동 소비하지 않는다.

일반 노트의 기존 Unicode/BOM 원문 비교·source hash·복구 원장 이름 whitelist·사용자 명시 선택과 GET 확인·동일 카드 refresh를 보존한다. 전용 검사에 실제 PDFKit 선택에서 만든 source card를 사용해 일반 노트 복구→외부 BOM/CRLF 제목·메모 재조회→기존 nodeID 유지→오래된 입력 거부→현재 메모 CAS/GET을 확인한다. PDFKit fixture를 읽지만 원본은 변경하지 않는다. 기존385/43 전체 검사를 반복하지 않는다.

## 최종 writer 검사 결과

7fa 결합 소스에서 일반 노트/PDF 카드 복구59건, 별도 BOM12건, 실제 Store 격리 PDF 복구/교차 보호17건, PDF/공식 conflict 전송 제한10건, anchor 재진입27건, PDF 늦은 응답/취소11건, normal snapshot3개 테스트를 통과했다. iOS27 SDK 전체 CanvasBridge DEBUG·Release typecheck 모두 exit0이며 컴파일 입력 hash가 실행 전후 동일하다. PDF 격리 실행에서 normal 보호 fixture15개가 불변이다. 06d 중간 단위에서는 기존 Canvas 복구68건과 DEBUG/Release 실제 복구 URL/파일 검사를 통과했으며, 이 기록을 최종 소스에서 재실행한 것으로 바꾸지 않는다.

추가 PDF 검사 작성 중 Swift try 배치 오류 한 건과, 중간 검사 입력을 편집한 시점의 컴파일 거부 기록은 evidence에 보존한다. 최종 영수증은 수정 후 sourceUnchanged=true인 결과만 통과 근거로 사용한다. 실제 UI 렌더링·HTTP는 이번 writer 검사 범위가 아니며 부모/서버 원담당의 별도 수용과 구분한다.
