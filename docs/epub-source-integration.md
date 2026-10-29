# EPUB 원문·발췌 접합

기준 f09daa176fb9ff8ff45dcb30389eb06f33ea2b40 / bd2347c35def444ca01dea8ec328c19e0ecffff0. 공식 WT와 Store/Workspace/Relay는 별도 소유다. 이 writer는 새 EPUB 파일·자체 검사·필요한 프로젝트 등록을 소유한다.

Pstack architect: Ground → 기존 PDF/노트 CAS와 REA 두 장·NCX 근거 대조 → 아래 API → 구현 → native/보안/SDK → 독립 검수. Ponytail: Foundation XMLParser·zlib·native text view·기존 VaultNoteReference를 재사용한다. 사용자 지시로 ARENA·새 DB·브라우저/HTML 실행은 제외한다.

## API와 책임

- `VaultEPUBSnapshot(path:bytes:)`: 사용자 경로의 UTF8 identity, 실제 archive SHA와 원바이트. sourceID는 경로 SHA이고 excerptID와 다르다.
- `VaultEPUBBook(snapshot:)`: 경계 있는 ZIP/XML 해석, 순서 있는 spine, NCX 목차, 장별 원문/XPath. 구조·자산 오류는 전체 거부한다.
- `VaultEPUBReader`: native 텍스트 읽기, UTF16 선택 발췌, 글꼴 변경, 같은 원문 발췌 복귀. 화면 페이지/좌표를 영구 앵커로 사용하지 않는다.
- `VaultEPUBExcerpt.markdown/parse`: 사람과 AI가 읽는 기존 Markdown 노트가 발췌/출처 계약의 단일 원장이다. 경로/hash/sourceID/spine item/XPath/UTF16/quote/excerptID를 담는다. scene 새 필드가 필요 없다.

## 필요한 제품 진입 접합 제안

1. Relay 소유자가 기존 bounded authenticated response를 재사용한 `vaultEPUB(at:) async throws -> VaultEPUBSnapshot`을 연결한다. 서버도 동일 token/허용 Vault 경로의 bounded EPUB raw 읽기만 제공한다. 폴더에서 연 원본은 별도 URL loader로 같은 snapshot을 만든다.
2. Workspace 소유자가 EPUB 목록/파일 열기를 native Reader에 연결하고 저장된 발췌 노트의 source payload에서 loader → snapshot SHA 확인 → Reader.reveal을 호출한다. 모든 await 뒤 기존 scene/연결/입력 epoch 검사를 유지한다.
3. 기존 durable 노트 생성/CAS/전체 GET 확인 및 카드 첨부 경로를 재사용한다. PDF 전용 parser/복구 원장을 EPUB으로 가장하지 않는다. 정확 source payload 지원을 기존 소유자가 좁게 확장하거나 generic note-create 복구를 소비한다. typed409/ACK 유실을 자동 성공 처리하지 않는다.

부모 직접 메시지 도구는 native ancestor 전송을 거부했고 Reason의 목록에 보인 주소도 수신되지 않았다. 그 전송을 완료로 세지 않는다. **후속 사용자 지시로 부모가 이 문서를 직접 확인했고 공유 Store/Workspace/Relay 접합을 Helm에게 별도 배정했다.** 전송 경로를 더 시험하지 않는다. 이 writer는 새 모듈·Reader·발췌 Markdown·pbx·자체 검사 단위를 반환한다. 이후 공식으로 확정된 `5fcb42cc1a1430a64210dd5d89c930a61fd8a0da` / `5c63f332fd6786adbd4291461c9f5b83e83f34c5`를 이 소유 브랜치에 소비했다. 프로젝트 충돌3곳은 PDF·EPUB 등록의 추가 union으로 해결했고 모든 기존 object는 EPUB 등록만 제거하면 공식과 같다. 공식 WT/브랜치는 수정하지 않았다. 실제 접합과 독립 source 판정 전에는 전체 EPUB 제품 UI 완료를 선언하지 않는다.

### Helm의 실제 callback 접합

`VaultEPUBReaderPanel(reader:relayAddress:saveNote:attachReference:isCurrent:)`를 제공한다. `saveNote(excerpt,markdown)`는 기존 durable intent에 같은 ID/path/원문을 먼저 보존한 뒤, 허용된 노트 PUT/CAS 및 전체 GET 결과를 `VaultNoteSnapshot`으로 반환해야 한다. 이 closure 내부에서도 기존 입력 epoch·연결·scene/source identity를 검사하고 typed409/ACK 유실을 보존해야 한다. Panel의 await 전후 `isCurrent()` 및 취소 검사는 카드 첨부를 막는 최종 경계이며 durable intent를 대체하지 않는다. `attachReference`는 기존 Store의 persistence-before-install/card Undo 경로를 소비한다.

실패·닫기·취소 시 `Reader.pendingExcerpt`는 같은 ID로 남으며 자동 재시도하지 않는다. 모듈은 이 메모리 상태를 durable 원장이라고 표시하지 않는다. 사용자가 다른 장으로 이동해도 미확인 발췌를 새 선택으로 덮지 않는다. 기존 발췌 노트에서 `VaultEPUBExcerpt.parse` → loader의 source path/SHA 확인 → `Reader.reveal`을 호출하면 같은 원문으로 돌아간다. `parse == nil`이나 변경·손상을 새 기본 앵커/검색 추정으로 바꾸지 않는다.

## 지원/보호 경계

ZIP은 원본을 풀어 파일시스템에 설치하지 않는다. 한도 있는 stored/deflate만 읽고 entry 경로·CRC·중복/정규화/교차참조를 검사한다. 암호화/DRM/ZIP64/미지원 extra, DTD/entity, script/event/원격 자원, 텍스트로 충실히 표시할 수 없는 미디어는 명시 거부한다. 제한에 걸린 입력도 원본 bytes를 삭제하거나 재작성하지 않는다. 첫 단위는 XML XHTML 텍스트·NCX이며 임의 EPUB 전체 지원이 아니다.

원본32MiB/entry4MiB/전개합64MiB/entry512개/압축비128/DOM깊이64/노드20000/요소별속성64/spine128/NCX깊이8·256항목의 고정 읽기 한도다. ZIP extra field는 현재 전부 미지원이다. archive 경로는 NFC·상대 경로만 허용하며 percent-escaped 이름을 추정 복원하지 않는다. XML은 UTF8만 지원하고 `p/heading/li/blockquote/pre`의 leaf 텍스트를 native paragraph로 표시한다. 이미지·SVG·수식·비어 있지 않은 CSS/inline style·hidden 속성이나 원문 텍스트를 누락시킬 복합 body는 성공으로 축약하지 않고 거부한다. NCX fragment는 직접 원문 문단 ID만 지원한다. NCX가 없는 책은 spine 장 목록으로 읽으며 EPUB3 nav 전체 지원을 주장하지 않는다.

`VaultEPUBSnapshot.writeVerifiedCopy`는 새 목적지에 exclusive create 후 원문 SHA를 재열어 확인한다. 기존 파일을 덮지 않으며 실패한 복사 후보도 자동 삭제하지 않는다. 원본 편집/자동저장/GC·FileProvider crash durability 수용을 제공하는 API가 아니다. 실제 노트 Markdown은 기존 note CAS가 단일 정본이고 native attributed text는 파생 표시일 뿐이다.

Mac MarginNote 4.4.6의 REA 동작이 근거다. 원앱 iPad/실제 GUI/Pencil 지원은 미검증이고 CCR native/소스/SDK·실제 기기 수용을 구분한다.
