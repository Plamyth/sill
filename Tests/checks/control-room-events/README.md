# iOS 관제 이벤트 Foundation 검사

원담당은 `01a13ace-e372-7ed1-9946-149df37ee1c3`이며 기준 후보는 `4f1c566`입니다. 기존 `ControlRoomProjection.swift` 전체와 `CanvasModel.swift`의 실제 `VoiceSession` 선언을 검증용 입력으로 추출합니다. Swift 앱 소스나 프로젝트 파일을 생성하지 않습니다.

```sh
python3 Tests/checks/control-room-events/run.py /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/ios-native-events-validation-20261023
```

출력 경로는 `storage-route`가 확인한 개발 보관 경로 안이어야 합니다. 순수 Foundation 컴파일·실행은 `mini-ephemeral-source`의 원담당·고정 작업 키를 사용합니다. 반환 로그에 종료 코드와 Mini 임시 사본의 `cleanup_verified` 영수증이 포함됩니다. 이 검사는 Git 체크아웃 이전이나 실기기 수용을 증명하지 않습니다.

`fixture.json`은 relay 통합 후보의 `relay/vendor/control-events/control-events-v1.json`과 같은 바이트입니다. 원본 공통 계약은 commit `f94f712e5c337a6415af2d33490aa6db285f9d2f`이며 fixture SHA-256은 `a026a9f697a88ebe2838e02c24b980774572683e35189962f4900eb059609454`입니다.

검사는 snapshot·patch·heartbeat, 세대·순서·중복·누락, 필드 제거, legacy 디코딩, 초기 unavailable, 원본 관측 시각과 30초 신선도, 4,002개 카드와 마지막 Cursor 두 카드, UTF-8·LF·CRLF·CR 프레임과 본문·전체 크기 제한을 확인합니다. URLProtocol 합성 전송으로 재연결 cursor, 오류, 미지원 응답, 취소, 최신 한 개 버퍼, 정책 삭제 뒤 단절 시 카드 비노출을 확인합니다. 연결 세대의 소유권도 검사합니다. 실제 HTTP 서버·UDS·앱·기기·오디오·키·모델·메시지를 사용하지 않습니다.

앱 빌드와 독립 검수는 별도 영수증입니다. UI 표시·OS 인증서 검증의 실제 연결·설치 앱과 실제 기기의 수용은 이 Foundation 검사로 주장하지 않습니다.
