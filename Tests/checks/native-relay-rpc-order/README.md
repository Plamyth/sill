# 네이티브 중계 RPC 순서 검사

맥북에서 이 작업의 정본을 기준으로 실행한다.

```sh
python3 Tests/checks/native-relay-rpc-order/verify-mini.py
```

저장 경로는 `storage-route`로 확인한다. 필요한 입력만 Mac mini의 원 담당 전용 한시적 경로에 전달한다. 실행 도구가 입력 해시, 종료 코드와 원격 삭제 확인 영수증을 남긴다. 맥북 원본과 Mini 입력의 전후 파일 해시도 검사한다. `.git` 없는 입력의 독립 코드 검사이며 Git 이전 수용이나 SDK 빌드 검증을 대신하지 않는다.

`run.py`는 실제 `LocalAudioRelay.swift` 전체에 같은 파일의 검사 접근자만 덧붙여 컴파일한다. 실제 `LocalAudioParticipants.swift`와 `AudioForwardingContract.swift`도 사용한다. 페어링 장치 자료형만 `RemoteAccess.swift`에서 추출하며 검사 인스턴스를 만들기 위해 추출본의 초기화 접근 수준만 조정한다. 공용 `call`, 파싱, 큐와 취소 구현은 바꾸거나 재구현하지 않는다.

비활성 Python child는 stdin과 stdout만 사용한다. 소켓을 열지 않고 오디오, HAL, 앱, 기존 서비스, 기기, 권한 또는 페어링을 조작하지 않는다. 준비 상태 응답은 이 child의 검사 데이터다. 성공 종료 전에 모든 검사 child를 종료하고 기다린다. 검사 프로세스가 실패하거나 제한 시간을 넘기면 해당 프로세스 그룹만 정리한다.

검사 범위는 FIFO 겹침, 전송되지 않은 취소와 마감, 전송된 요청의 실패 시 폐쇄, 전체 대기 정리, sequence 상한, 요청 식별자와 부팅 식별자 및 PID, 엄격한 JSON, 등록된 참여자 콜백, prepare receipt 및 대기를 포함한 최대 5초 예산이다. 마지막 admission은 슬롯 획득 후 실제 전송을 예약하는 MainActor 구간에서만 호출한다. 거절과 전송 전 취소는 sequence를 소비하지 않는다. 실제 coordinator의 scope와 보호 증명 검증은 부모가 연결한다.

Mac SDK 전체 빌드, 실제 Node 계약 상호 실행, 실제 오디오와 기기 동작은 이 검사 범위에 포함하지 않는다.
