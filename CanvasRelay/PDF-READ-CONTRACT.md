# PDF 읽기 소스의 일반 노트 복구 위 접합

기준 공식 commit은06d7e6d50804e7c8d90551275891df76e2e544cf/tree99ab9bc9ccc23544cfc7aa073c9dfcd9c8d77cdf다. 이 기준의 CanvasRelay subtree35a226ce52c6e51f21c02587ecad425064382467은 SOURCE_CLEAR f6e7b7d와 같다. 공식964의2c90 서버에 PDF만 추가해 일반 노트 복구가 포함된 것처럼 표시하지 않는다.

Dalton의 기존 c416ef0205399f17ef4ad26aa6d50b5797ef0aa7ceb294d8b30d00d702b52030 패치를 그대로 소비했다. 원래2250dfad의 PDF read 계약을 f6계보 위에 의미 접합한 단위다. 제품 변경은 obsidian-vault.js와 server.js 두 파일뿐이다. 원장의 #privateDirectory부터 일반 노트와 Canvas resolver를 포함한 끝부분은 f6 원본과 바이트가 같다. 기존 Canvas/일반노트 route·DTO·typed409·auth·atomic preserve는 그대로다.

entries는 기존 directory/note에 소문자 .pdf 일반 파일의 kind:pdf를 추가한다. GET /vault/pdf?path=기존상대.pdf 는 기존 X-Canvas-Token 안에서만 동작하며 응답은 {path,sha256,dataBase64}다. PDF 쓰기 route는 없다. 일반 note/save는 계속 .md 전용이다.

PDF의 최대 크기는20MiB다. Vault 경로 검증으로 절대·숨은·dot·중복slash·backslash·NUL·symlink를 거부한다. root부터 leaf의 dev/ino와 no-follow FD identity를 읽기 전후 대조하고, 일반 파일·제한 크기·실제 최대20MiB+1 bounded read·size/mtime/ctime 변화·%PDF- signature를 검사한다. 이 단위는 PDF 전체 포맷 파서나 렌더링을 구현한 것이 아니다.

집중 검사는 PDF 목록/인증/읽기전용, 경로·크기·signature 거부, 읽기 중 파일 성장, 부모 symlink 교체의4개다. snapshot/hiddenPolicy는 synthetic root의 부재 경로만 사용하며 listener/connect/fetch/datagram을 금지한다. run-checks.py --pdf는 이4개만 실행하며 main Node PID 종료와 원문/입력 SHA, 한시 소스 삭제를 기록한다. 같은 제품 SHA의 Dalton PDF4/일반노트16 근거는 별도 보존하고 불필요한 전체 회귀를 반복하지 않는다.

현재 일반노트 actualHTTP는 별도 exactf6 서버에서 검증했고 이 PDF 패치는 포함하지 않았다. PDF의 실제 HTTP/앱 렌더/설치/실기기/공유런타임 수용으로 표시하지 않는다. source/검사/공식 통합/설치 수용은 분리한다. 부모가 단일 공식 통합을 소유하며 이 branch에서 push/PR/merge/8791/8793·Host·사용자vault·기기 변경은0이다.

## FIFO 교체 경계 후속

6475df0의 독립 SOURCE_CLEAR는 FIFO 교체 반례 이전 범위로 보존한다. Mini의 별도 자식에서 regular 원본을 rename 보존하고 마지막 stat/open 사이 mkfifo로 바꾼 실제 open은 1.2초 timeout에 도달했다. O_NONBLOCK을 PDF open에 추가해 기존 dev/ino·samePath·regular fstat 검사까지 즉시 진행하도록 한다. 이 flag는 일반 파일의 바이트 읽기 의미를 바꾸지 않는다. vault-pdf-fifo.test.js는 동일 교체에서409, PDF read0, FD close, 자식 PID 부재, 원문 SHA 보존과 fixture 정리를 확인한다. 새 HTTP 검사는 이 수정의 정확한 후속 서버 commit을 별도로 고정한다.
