# Host243 양방향 음성 중단

1. Reproduce it yourself on the matching surface via the driver skill.
   - 기존 iPad87 실물 시험 영수증과 08:10 Host 원본 로그를 재사용. 동일 ON 반복 없음.
2. Binary-search the cause.
   - Root: ingress/화면 세대/relay; 독립 지원: HAL runtime; iPad 담당: 기존 클라이언트 취소 근거.
3. Plan the fix.
   - 확정 원인에 필요한 공유 경로만 변경. 로컬 음소거·신뢰·권한 경계 보존.
4. Verify on the same surface.
   - 의미 있는 회귀 → SDK 빌드 → 독립 검수 → 동일 후보의 짧은 공유 Host 전환·iPad 시험.
   - Vision 착용 시험은 사용자 지시에 따라 보류.
5. Stage the commits so the failing repro lands before the fix in git history.
6. Run Opening a PR.

종료: 확인된 원인 수정, 정확 소스 커밋·검수·설치 readback·미디어 결과 연결. 새 가설 없는 동일 실패 반복 금지.
