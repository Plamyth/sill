# Dock 액션 실패 복구 검사 결과

작업 키는 `host-dock-rollback-checks-20261021`, 담당 대화는 `01a15afa-e54c-76c1-815b-434c884226ff`다. 검사 전용 워크트리를 `63283efd9322ed66cd079186e5091bcf4083342e`에서 만들었다. 이 담당은 생산 코드를 수정하지 않았다. 최종 독립 검수는 다른 검수자의 후속 단계다.

기존 비활성 재현의 실제 `handleDockRequest`, `select`, `startPipeline` 본문을 검사 실행기에 통합했다. 복구 캡처를 보류한 상태에서 ingress 등록 제거, 다른 창의 새 ticket 발급, transport 취소, 페어링 해제를 각각 적용한다. 등록 제거는 transport를 취소하지 않으며 transport 취소는 ingress 등록을 제거하지 않는다.

| 생산 소스 | 동작 검사 | 기존 변이 검출 | 종료 코드 |
| --- | --- | --- | --- |
| `63283efd9322ed66cd079186e5091bcf4083342e` | 기존 36개와 정상 복구 통과, 복구 취소 4종 실패 | 4/4 | 1 |
| `fa08de63c40434a55cddca5c647a4c28fab5344a` | 41/41 | 4/4 | 0 |

수정 전 실패 4건은 모두 `commit=1, active=window(7), capture.running=true`를 관측했다. 새 ticket은 이전 창과 다른 `.window(17)`을 선택한다. 부모 수정 후에는 네 취소 사례가 commit 0회, 미확정 소스와 epoch, 양쪽 캡처·콜백·준비 epoch 정리를 확인한다. 정상 실패 복구는 `.window(7)`과 동일한 epoch·catalog를 한 번 확정하고 캡처를 유지한다.

수정 전 실행 결과는 외장 개발 경로의 `host-native-dock-20261021/pipeline-checks/rollback-checks-01a15afa-20261021/base-red-v1`에 보존했다. 부모 수정 후 결과는 같은 작업 경로의 `parent-green-v1`에 보존했다. 각 `result.json`에는 생산 소스 경로·commit·tree·미커밋 상태, 검사 경로·commit·tree·미커밋 상태, 입력 및 추출 함수 해시, 컴파일과 실행 명령·종료 코드가 있다. 두 실행 모두 `sourceUnchanged=true`, `testsUnchanged=true`다. 실행 당시 검사 변경은 미커밋 상태였으며 그 상태와 해시도 영수증에 남아 있다.

기존 36개 검사 이름과 기존 4개 변이의 이름·검출 사례를 대조한다. 변이는 대상 함수 또는 admission 생성 closure에만 적용하므로 실제 `handleDockRequest`와 검사 보조 함수에 같은 closure가 있어도 다른 위치를 잘못 바꾸지 않는다.

다음 기존 실패 영수증은 변경하지 않았다.

- `RESULT.md`, `result.json`
- `RESULT-P2-20261021.md`, `result-p2-fix-20261021.json`
- 외장의 `independent-rollback-63283efd-20261020T202520Z/exact-body/result.json`

이전 재현 영수증의 SHA-256은 `fd36c8ccd7797ed49bc1045bf5f36fde40c73daf6253fe91e2914c8cedd18dab`다. 보존 파일 해시는 외장 작업 경로의 `retained-receipts.json`에 기록했다.

재실행 명령은 `README.md`의 부모 소스 경로 명령을 사용한다. 출력 경로는 기존에 없는 새 라벨이어야 한다. 이미 존재하는 디렉터리에는 쓰지 않는다. 실제 OS·AX·앱·기기·오디오·HAL·설치·재시작은 실행하지 않았다. ARENA도 실행하지 않았다.
