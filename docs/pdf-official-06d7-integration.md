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
