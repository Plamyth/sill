# 문서 전체 릴레이 v1

기준 공식9006908998dbcbe0b278b3dc75c71d5d2006342a. 모델0fd008a의독립검수는CHANGES_REQUESTED이며 모델/Files 수리최종객체와추가대조한다. 형식명·DTO·한도계산은부모가수용한설계의구현선택이며사용자가각세부값을직접정한것으로기록하지않는다. iOS/Core/기존packet은이단위에서수정하지않는다.

기존인증 GET /vault/canvas/capabilities 응답에 document:ccr.vault-document/v1 기능을추가한다. format=ccr.canvas-document,versions=[1],wholeDocument/explicitConflictResolution=true이며한도를포함한다. capability 부재/404/미지원이면클라이언트는문서원본을미동기화로보존하고선택scene으로fallback하지않는다. 서버의기존13MiB scene 제한은그대로다.

GET/PUT /vault/document?id=소문자UUID를사용한다. PUT은정확히base/documentJSONBase64/documentSha256/pages를받는다. base는신규null또는noteSha256/documentSha256/manifestSha256의3개SHA다. pages는document.pages와순서가같고각id/drawingSha256/previewSha256/previewPNGBase64를갖는다. drawing 원본은문서JSON의drawingBase64에서추출하며별도중복전송하지않는다. GET은schema/id/path/revision/activePageID/noteSha256/documentSha256/manifestSha256/generation/pages/documentJSONBase64를반환한다. 모든페이지와원본JSON바이트를그대로보존한다. GET과서버저장성공은서버의구조·SHA·PNG검증이며PKDrawing의네이티브해석검증을대신하지않는다.

wire 한도는JSON16MiB의base64최대4*ceil(N/3), preview합계32MiB의128개분할padding최대4*floor((P+2*128)/3), 최악길이의base/SHA/UUID/128개빈base64메타데이터를실제JSON.stringify한30328bytes의합이다. 결과67139536bytes(64.029251MiB)로65MiB미만이다. 전송자는불필요한slash escaping/pretty print 없이JSON을만들어야최대한도자료를전송할수있다. 작은여유를추정해일반한도를전역확장하지않는다. 초과는문서경로만413/document_too_large, publicationAttempted:false로거부하며파일쓰기0이다.

CCR Documents/문서UUID.md가유일한발행지점이다. Assets/문서UUID/generationUUID/ 아래manifest.json은FilesHead v2와같은 schema/documentID/generation/documentSHA/pages(id,drawingSHA,previewSHA)를갖고, document.json과pages/페이지UUID/drawing.pkdrawing,preview.png를불변새세대로먼저쓴다. canonical Markdown에는전페이지순서·원본/preview링크가있으며표시글자는문서전체64KiB예산안에서만파생한다. 생략표시가있어도원본JSON/모든자산은보존한다. 기존memo suffix는BOM/CRLF/NFD포함재작성하지않는다. 기존generation은삭제하지않는다. Files current.json과릴레이noteSha256은다른CAS token이다.

새문서의기존단일scene과같은UUID승격은기존scene과해당원본페이지가동일할때만허용하며현재memo를복사한다. 기존단일노트/자산을삭제·덮지않는다. 생성후문서UUID와모든페이지UUID는기존scene endpoint/일반MD/일반MD resolver와hardlink별칭우회로저장하지못한다. ID소유는기존canonical문서와vaultroot의기존.ccr-save intent에서파생하며새DB/상위원장은없다.

교환직전까지의불일치는document_stale로원본을유지한다. 교환시도뒤정본경로·자산·SHA·내구성확인실패는기존note_reconciliation_required/reconciliationRequired/recoveryID/publicationAttempted의typed409다. 문서노트의.ccr-save 원장은CCR Documents 부모교체에도남도록configured vaultroot에둔다. base/displaced/proposal 원문과기존교환primitive/owner/no-follow/nonblocking/identity검사를재사용한다. 성공SHA나pendingSHA가같아도barrier를자동해제하지않는다. ACK유실후클라이언트는문서전체재열기와원장상태를확인할때까지초안·요청의도를유지한다. 비협력writer의미래쓰기나configured vaultroot 자체교체를절대배제하는CAS라고주장하지않는다.

GET /vault/document/conflict?id=UUID는ccr.document-conflict/v1과기존expected5개에bundlesSha256을추가한expected,자료4종의markdownBase64/sha256/validDocument/전체세대메타데이터/history를반환한다. JSON총8MiB로제한한다. 큰후보는같은GET에recoveryID/material(active|base|displaced|proposal)/sha256을추가해하나의전체bundle로읽는다. caller path/text는받지않는다. PUT은기존3필드recoveryID/expected/decision(keepCurrent|useDisplaced)만허용한다.

선택후문서전체와모든자산을새Vault에서재검증하고최종정본SHA·보존자료·독립새충돌을확인한뒤durable resolution을기록한다. 같은ID/같은결정/상태는멱등반환하고새독립held가우선한다. 선택본의자산을재열수없으면명시거부하고모든자료를보존한다. 자동rollback·자동선택·원장삭제는없다. Core 소비는원담당의문서ID/pageID/documentSHA 계약확정전연결하지않는다.
