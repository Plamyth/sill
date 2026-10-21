# Host 오디오 중계 Node 소스 고정

대상 Node commit은 `24190a6af7306e06b9e681042034f8556c8942fb`, tree는 `7d52e175a9065d3493acf330c917c67fa30ff364`이다. 기존 필수 계약인 `manifest.nodeSourceCommit`과 `LocalAudioRelayManifest.nodeCommit`을 유지하며 새 필드를 도입하지 않는다.

서버 봉인 해시표도 함께 갱신한다. `server/audio-forwarding-proxy.js`의 기대 SHA-256은 `b7cdb3504785a315a2c1ed304e0d62583c60506f70c8fad0f56231c1337ff48c`이며 실제 proxy 바이트와 일치해야 한다. proxy 바이트와 매니페스트 해시를 함께 변조해도 거절하는 검사로 확인한다.

이전 `1f846e8b776dec9b504cebf78735e57dc1ad5cda` 대비 서버 모듈 16개 중 proxy 1개가 바뀌고 15개는 같다. 이 Git 객체 비교의 검증 책임은 부모 담당에게 있다. 패키징에는 대상 commit의 실제 proxy 바이트와 그 SHA-256을 반영해야 한다. 매니페스트의 commit만 바꾼 패키지는 수용 대상이 아니다.

이전 절차는 `/Volumes/BT-Workspace/Development-Archives/control-room-mobile/host-official-audio-pin-20261021-reviewed.json`을 재사용한다. 해당 영수증은 이전 버전의 근거이며 이번 버전의 통과 증거가 아니다. 부모 담당이 정확한 소스의 source guard 확인, Git 객체 비교와 Mini 봉인 검사를 수행하고 공통 Host 원담당이 검수 결과를 바탕으로 최종 수용한다.

이번 변경은 세 코드 파일의 commit 상수와 이전 `1f846e8` 매니페스트를 명시적으로 거절하는 사례, 이 문서로 한정한다. 기존 `633`, `aa98`, `97f` 거절 사례는 유지한다. 테스트·빌드·제품 실행·설치·Host 재시작·HAL·Hog·UI·기기 조작은 수행하지 않았다. 설치 및 실물 수용은 미완료다.
