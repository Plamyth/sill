# Read-only catalog query

Owner 01a13ace-e372-7ed1-9946-149df37ee1c3. Base143a0cf6abd927fe05846bd66137876bd139cae7.
Port the authenticated read-only212 contract from reviewed Vision7f32300 without replacing older host functions.

- [x] Ground. Existing catalogs use SourcePublicationAdmission through send and replay. Generic send rejects windowList. The paired TLS route and an existing live grant identify a query response. HostAudioPrivacy.verify can schedule repair, so a read-only query must not call it.
- [x] Sketch. A separate query sender duplicates publication, epoch and replay checks. Reuse sendCatalog and optional correlation fields. This is a sequential comparison because the available worker is occupied with independent iPad media revocation work.
- [x] Agree. FetchCatalog owns a UUID; WindowList carries optional capability and response UUID. A queued query whose grant expires gets the same response ID with microphone/privacy removed. Changed source admission, pin, epoch or connection gets no stale response.
- [ ] Implement. Wire scaffold and failing queued-expiry test first, then actual handler and sender correction. Queries inspect cached protection and existing grants; no arm, verify/repair HAL, new grant or source selection.
- [ ] Scrap. Re-ground if this requires bypassing source publication or restoring an old complete function.
- [ ] Verify actual extracted queue/query methods, preserved source/privacy/display fields, full SDK and independent review. No installation or shared host effects.

Throughput checkpoint: exact methods and controlled wire queues run as Mini RAM inputs. Apple SDK builds use the local native toolchain. No remote source copies or source-guard migration claims.

Pstack how/architect/TDD and Ponytail full reuse the existing typed catalog and publication path. Original-app reconstruction remains open.
