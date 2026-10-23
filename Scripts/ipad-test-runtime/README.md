# iPad 통합 테스트 연결

`descriptor.json`은 전역 release convergence 등록 담당이 사용할 명령과 수용 항목이다. 경로 자리표시는 배포된 clean integration worktree와 비공개 설정 파일의 절대 경로로 바꾼다. 이 파일 자체는 managed 등록이나 운영 배포 허가가 아니다.

`adapter.py deploy --config PRIVATE_JSON`은 clean `integration/ccr-ipad`의 원격 source guard를 확인하고 실사용 Sill과 다른 REA 전용 진단 bundle을 Debug로 빌드·설치한다. 기존 Sill 설치는 덮어쓰지 않는다. Info.plist에 정확한 commit/tree를 넣으며, 기기에서 실행 중인 앱이 만든 runtime.json의 실행파일 SHA와 대조한다. 시험 UUID의 저장 경로와 relay 연결을 사용한다. 원래 keychain 연결과 그림을 옮기지 않는다. 테스트 시작 전후 사용자 상태의 바이트를 비교한다.

`adapter.py accept --config PRIVATE_JSON`은 별도의 쓰기 가능한 Obsidian 시험 보관함과 릴레이에서 실제 글자 선택 삭제·Undo·Redo·저장·Mac 수정·재열기를 실행한다. UI runner는 이 저장소의 XCTest 소스이며 기존 REA 진단 bundle을 재사용한다. 실제 보관함 JSON/PNG/Markdown과 기기 파일을 대조하고 인증 거부·오래된 버전 거부·시험 데이터 초기화를 확인한다. 외부 대화 전송 provider는 연결하지 않는다. 실패는 JSON held와 비정상 종료로 반환한다. 실제 Pencil 종류·압력·호버·MyScript 제스처 동등성은 이 검사의 수용 항목이 아니다.

회전 검사는 두 노드·명시 연결점이 있는 자체 장면에서 실제 손가락 드래그로 45도와 90도 회전, 저장·재열기를 확인한다. PNG는 실제 iPad의 production SceneRenderer가 만든 전체 크기 이미지여야 한다. Python 표준 zlib로 청크 CRC·IDAT 스트림 종료·Adler-32·행 크기를 엄격하게 검증한 뒤, macOS 기본 ImageIO와 기존 NativeSceneEncoder로 실제 PNG를 디코딩하고 회전된 노드 내부와 경계 밖, 명시 연결점 사이 여섯 위치의 픽셀을 확인한다. 빈 이미지·손상 이미지·회전 전 연결선·1픽셀 준비용 이미지는 수용하지 않는다. iPad 화면도 노드의 실제 화면 좌표와 회전각으로 같은 여섯 연결선 위치를 검사한다. 별도 Python 이미지 라이브러리 설치 없이 등록된 `/usr/bin/python3`에서 실행한다. Mac 수정은 같은 장면 JSON·PNG를 SHA 조건 PUT으로 반영하고, 열린 앱의 준비 마커를 받은 뒤 한 번만 실행한다. 앱의 최신 내용 수신 표시·90도 표시와 재열기, 기기 파일·보관함 JSON 일치를 확인한다. 회전값을 확인한 것만으로 실제 Pencil 입력이나 연결선의 시각 수용을 주장하지 않으며 xcresult 화면을 별도로 검수한다. 회전 화면 증거 PNG는 시험 보관함 초기화 전에 작업 증거로 보존한다.

비공개 설정은 `repo`, `outputRoot`, `leaseFile`, `deviceUDID`, `developmentTeam`, `relayRepo`, `relayCommit`, `nodeExecutable`, `relayHost`, `relayPort`를 가진다. 출력은 storage-route가 확인한 BT_CCR-ipad development archive의 하위 경로다. 릴레이는 등록된 integration 포트 8793과 private IPv4를 쓰며, 기존 승인된 relay 소스의 commit을 고정한다. 인증 token은 출력의 0600 비공개 파일에만 생성된다. 설정·lease·token·사용자 그림은 Git에 넣지 않는다.

lease는 `ccr.device-lease/v1` schema, 원래 owner, 정확한 deviceUDID, 시간대가 있는 expiresAt, install/launch/copy/test actions, 실제 사용권 근거인 handoffEvidence를 가진다. lease 파일을 만든다는 사실로 사용권이 생기지 않는다. 현재 담당의 실제 반납 또는 이미 확인된 독립 기기 사용권을 근거로 등록해야 한다. 다른 기기의 시험은 병렬 가능하며 공유 Mac 화면·입출력·호스트 변경은 별도 조율한다.

기술 검사 명령은 `python3 -B Scripts/ipad-test-runtime/test_adapter.py`다. 스크립트 통과만으로 실제 기기나 전역 testAccepted를 기록하지 않는다. acceptance 영수증이 모든 검사를 증명하고 전역 원장이 같은 commit/tree/runtime를 확인해야 한다.

임시 릴레이는 전역 서비스 원장에 등록된 `ccr-ipad-integration-relay-8793` 하나만 사용한다. `bt-service-lifecycle start`로 원래 owner와 900초 TTL을 등록하고 시험 중 renew, 종료 시 release 결과를 기록한다. 등록이 없거나 같은 포트·세대가 사용 중이면 새 listener를 만들지 않는다. 다른 담당 서버나 실제 사용자 relay 8791을 정리 대상으로 삼지 않는다.
