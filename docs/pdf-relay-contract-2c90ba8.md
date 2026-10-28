# PDF 릴레이 접합 계약

부모가 공식 통합과 서버 반영을 소유한다. 이 구현 단위는 iPad 클라이언트와 서버용 별도 패치만 반환한다. 현재 공유 서버, Galileo 작업트리와 원본 relay는 수정하지 않았다.

서버 기준은 `2c90ba8a5fed8715988e9f98da904203dca13504`, tree `5a0431985a37a41caa9ca1200b17d5e9495d90b9`다. 보존 원본은 별도 relay Git의 `2250dfada987013e6fc09e40e8bf2a58db134245`, tree `8a66ad83f3d2c98b96f546f850bcb19cceb1f36d`다. 예전 전체 파일을 교체하지 않는다.

[최소 패치](patches/canvas-relay-pdf-2c90ba8.patch)는 두 제품 파일만 변경한다. 기본 `.md` 쓰기 계약, typed 409, case 결속, 보존 원장과 원자 저장은 그대로 둔다. `resolve`에 읽기 전용 PDF 옵션을 추가하고 `entries`에 `kind: "pdf"`를 반환하며 기존 인증 분기 안에 PDF GET을 연결한다. PDF 쓰기 API는 없다.

- `GET /vault/entries?path=상대폴더`의 기존 entries 배열에 PDF 항목을 추가한다.
- `GET /vault/pdf?path=상대경로.pdf`는 기존 `X-Canvas-Token`을 확인한다. 응답은 `{path, sha256, dataBase64}`다.
- 소문자 `.pdf`, 20 MiB 이하 일반 파일, `%PDF-` 시그니처를 요구한다. 숨김·traversal·심볼릭 경로를 거부한다. `O_NOFOLLOW`, 경로 및 FD의 dev/ino, 최대 크기+1 제한 읽기, size/mtime/ctime 전후 검증을 보존한다.
- PDF의 노트 출력은 기존 `PUT /vault/note`에 `{baseSha256:null,text}`를 보낸다. 같은 `발췌-UUID.md` 경로를 유지하고 별도 GET의 정확한 UTF-8을 확인한다. 응답 유실 때 새 ID나 자동 재전송을 만들지 않는다.
- 클라이언트는 새 노드 kind·scene schema·인증을 추가하지 않는다. 기존 `.note` 카드가 `.md`를 참조하고 Markdown 안의 출처만 PDF를 가리킨다. 선택은 한 페이지·rotation 0으로 제한한다.

제품 파일 해시는 다음과 같다.

| 파일 | 기준 SHA-256 | 패치 후 SHA-256 |
| --- | --- | --- |
| `CanvasRelay/relay/obsidian-vault.js` | `7d28fcc405b4a92df656eb1579fe47223b00b4d2d830e6c27b979127b5be2af6` | `d5fc1ac02283ac729baf0d12d1cc1c114390bea5bb8d054aa04ad4952841bfbe` |
| `CanvasRelay/relay/server.js` | `fee006347c172e96b017ea4325fddc327d26799032d68143bdb8247afa2ca77f` | `dab5368fe45471f2095e319dbce22276171090475e165bf20e12cd59cdde5a06` |

패치 SHA-256은 `9eeae94eae2724ab174c6501b8aefb9fccb3c22703cb1964145a2e2d19a9c398`다. Galileo가 정확한 clean 2c90ba8에서 `git apply --check`와 두 파일 SHA를 독립 재대조했다. 이 결과는 기계적 접합 확인이며 PDF 제품 전체의 독립 검수 판정은 아니다.

소켓 금지 Mini PDF 검사 4개와 기존 서버 회귀 146개 통과·1개 skip을 확인했다. 두 실행의 입력 SHA 불변과 Mini 사본 삭제를 확인했다. Swift Store·PDFKit과 이 패치 snapshot의 격리 파일 왕복 106개도 통과했다. 이는 표준입출력의 실제 파일 검사이며 HTTP·공유 서비스·iPad 설치·Pencil 수용은 수행하지 않았다. 영수증은 작업 루트 `../evidence/relay-pdf-manifest.json`, `relay-pdf-mini-current-receipt.log`, `relay-regression-mini.log`, `file-roundtrip.log`에 있다.
