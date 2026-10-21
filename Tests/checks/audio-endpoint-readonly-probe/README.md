# 오디오 장치 읽기 전용 진단

Python 3 표준 라이브러리만 사용합니다. Host 실행이나 설정 변경 없이 공개 CoreAudio 속성을 조회합니다.

```sh
cd Tests/checks/audio-endpoint-readonly-probe
python3 -B -m unittest -v test_probe.py
python3 -B probe.py --device-name DN32-LIVE --output /승인된/경로/result.json
```

출력 경로는 먼저 `storage-route path development-archive --project control-room-mobile --filename 이름.json`으로 확인합니다. 기존 파일은 덮어쓰지 않습니다. 같은 경로의 결과가 있으면 내용을 먼저 확인합니다. `--device-name`을 반복하면 지정한 장치의 채널 속성만 조회합니다. 필터와 일치하지 않는 장치는 `requestedNamesMissing`에 표시합니다.

장치의 실제 입력·출력 채널 수에 따라 master 0과 채널 1..N의 mute, scalar volume, dB volume을 각각 기록합니다. 속성 없음, 조회 실패, 설정 가능성, 현재 값을 구분합니다. 설정 가능 여부 조회는 설정 쓰기가 아닙니다. 독점 소유 PID는 부호 있는 값으로 기록합니다. `-1`을 큰 양수 PID로 바꾸지 않습니다.

조회 전후 장치 목록·UID·기본 장치 세 종류·독점 소유·실행 상태를 비교합니다. 비교 가능한 값의 차이가 있으면 다른 조회가 실패해도 `anchorsUnchanged=false`로 기록하고 `observedAnchorChanges`에 남깁니다. 차이를 확인하지 못했고 비교도 불완전하면 null입니다. true도 원자적 스냅샷이나 중간 변경 부재를 증명하지 않습니다. 각 속성의 개별 실패는 별도로 확인해야 합니다.

진단은 음소거·볼륨·독점권·기본 장치를 바꾸지 않고 I/O를 시작하지 않습니다. 현재 오디오 샘플이나 인증정보도 읽지 않습니다. 현재 실행 값은 장치 단위 표본이며 실행 프로세스 목록이나 차단 성공 증거가 아닙니다. 해당 속성이 없다는 결과를 모든 공개·공급업체 제어 수단이 없다는 결론으로 확대하지 않습니다. 실제 보호·호스트 종료 후 지속성·원격 음성 수용은 별도 시험이 필요합니다.

기존 `audio-endpoint-capability-followup-20261021.json`은 과거 관측입니다. 이 도구는 그 일회성 진단을 반복 가능한 코드로 남기는 목적이며, 과거 값을 현재 관측으로 사용하거나 같은 값을 새 보호 성공으로 보고하지 않습니다.
