import Foundation
import StreamProtocol

var failures = 0
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { failures += 1; print("FAIL \(message)") }
}
func rejects(_ operation: () throws -> Void) -> Bool {
    do { try operation(); return false } catch { return true }
}

let decoder = JSONDecoder()
let encoder = JSONEncoder()
let fixture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let catalog = try decoder.decode(TestDestinationCatalog.self, from: fixture)
let entry = catalog.entries[0]
check((try? catalog.validate()) != nil, "exact PC catalog accepts nullable checkedAt and reason")
check(entry.projectId == "fixture-project", "public projectId matches JSON")
check(entry.checkedAt == nil && entry.reason == nil, "unknown dates and reason stay nil")
let roundTrip = try decoder.decode(TestDestinationCatalog.self, from: encoder.encode(catalog))
check(roundTrip == catalog, "common catalog preserves wire values")
let encoded = try JSONSerialization.jsonObject(with: encoder.encode(catalog)) as! [String: Any]
check(Set(encoded.keys) == ["schema", "observedAt", "entries"], "no fabricated wire scope or revision")
let encodedEntry = (encoded["entries"] as! [[String: Any]])[0]
check(encodedEntry["projectId"] != nil && encodedEntry["projectID"] == nil, "lower camel projectId encoded")

check(entry.redirectOrigins.isEmpty, "omitted redirect origins decode as empty")
let redirects = ["https://login.example.test", "https://Macbook.local:8443"]
var redirectEntry = entry
redirectEntry.redirectOrigins = redirects
check((try? redirectEntry.validatedRedirectOrigins())?.count == 2, "exact HTTPS and nonloopback LAN redirect origins allowed")
let redirectRoundTrip = try decoder.decode(TestDestinationCatalog.Entry.self, from: encoder.encode(redirectEntry))
check(redirectRoundTrip == redirectEntry,
      "redirect origin registration survives wire round trip")
for origin in ["http://login.example.test", "https://login.example.test/", "https://login.example.test/path",
               "https://login.example.test?", "https://login.example.test#", "https://user@login.example.test",
               "https://localhost", "https://127.0.0.1", "https://[::1]", "https://*.example.test",
               "https://login.example.test:0", "https://login.example.test\\@localhost"] {
    redirectEntry.redirectOrigins = [origin]
    check(rejects { _ = try redirectEntry.validatedRedirectOrigins() }, "unsafe redirect origin rejected \(origin)")
}
redirectEntry.redirectOrigins = (0..<8).map { "https://login\($0).example.test" }
check((try? redirectEntry.validatedRedirectOrigins())?.count == 8, "eight redirect origins accepted")
redirectEntry.redirectOrigins.append("https://ninth.example.test")
check(rejects { _ = try redirectEntry.validatedRedirectOrigins() }, "ninth redirect origin rejected")
var invalidRedirectCatalog = catalog
invalidRedirectCatalog.entries[0] = redirectEntry
check(TestDestinationCatalog.Projection(invalidRedirectCatalog).catalog == nil, "invalid redirect origins invalidate projection")

func replacingEntry(_ change: (inout TestDestinationCatalog.Entry) -> Void) -> TestDestinationCatalog {
    var value = catalog
    change(&value.entries[0])
    return value
}
var invalidCatalogs: [(String, TestDestinationCatalog)] = []
var unsupported = catalog
unsupported.schema = "ccr-test-destinations/v2"
invalidCatalogs.append(("unknown schema", unsupported))
var duplicate = catalog
duplicate.entries.append(entry)
invalidCatalogs.append(("duplicate IDs", duplicate))
var oversized = catalog
oversized.entries = (0...TestDestinationCatalog.maximumEntries).map { index in
    var value = entry
    value.id = "entry-\(index)"
    return value
}
invalidCatalogs.append(("entry bound", oversized))
var badObservation = catalog
badObservation.observedAt = "yesterday"
invalidCatalogs.append(("invalid observation date", badObservation))
badObservation.observedAt = "2026-10-20T09:00:00Z trailing"
invalidCatalogs.append(("trailing date garbage", badObservation))
invalidCatalogs.append(("empty owner", replacingEntry { $0.owner = "  " }))
invalidCatalogs.append(("empty id", replacingEntry { $0.id = "" }))
invalidCatalogs.append(("empty projectId", replacingEntry { $0.projectId = "" }))
invalidCatalogs.append(("empty project label", replacingEntry { $0.projectLabel = "" }))
invalidCatalogs.append(("empty label", replacingEntry { $0.label = "" }))
invalidCatalogs.append(("invalid checkedAt", replacingEntry { $0.checkedAt = "unknown" }))

let rejectedURLs = [
    "https://localhost/screen", "http://sub.localhost/screen", "http://localhost./screen",
    "http://local/screen", "http://localhost.localdomain/screen",
    "http://127.0.0.1/screen", "http://127.9.8.7/screen", "http://127.1/screen",
    "http://2130706433/screen", "http://0x7f000001/screen", "http://0177.0.0.1/screen",
    "http://[::1]/screen", "http://[0:0:0:0:0:0:0:1]/screen",
    "http://[::ffff:127.0.0.1]/screen", "http://[::ffff:7f00:1]/screen",
    "http://[::ffff:169.254.169.254]/screen", "https://[::ffff:a9fe:a9fe]/screen",
    "http://[::169.254.1.2]/screen", "http://00127.0.0.1/screen", "http://169.0254.1.2/screen",
    "http://0.0.0.0/screen", "http://[::]/screen", "http://169.254.1.2/screen",
    "https://person:secret@example.test/screen", "https://person@example.test/screen",
    "https://@example.test/screen", "file:///screen", "javascript:alert(1)",
    "data:text/html,fixture", "/relative", "//example.test/screen", "https:///screen",
    "https://example.test:0/screen", "https://example.test:65536/screen",
    "https://example.test/with space", " https://example.test/screen", "https://example.test\\@localhost/",
    "https://example.test/%ZZ", "https://example.test/invalid%", "https://example.test/<invalid>"
]
for url in rejectedURLs { invalidCatalogs.append((url, replacingEntry { $0.url = url })) }
for (name, invalid) in invalidCatalogs {
    check(rejects { try invalid.validate() }, "reject \(name)")
    let projection = try decoder.decode(TestDestinationCatalog.Projection.self, from: encoder.encode(invalid))
    check(projection.catalog == nil, "projection isolates \(name)")
    check(TestDestinationCatalog.Projection(invalid).catalog == nil, "initializer isolates \(name)")
}
for hostname in ["Macbook.local", "Macbook.localdomain"] {
    let lan = replacingEntry { $0.url = "http://\(hostname):8080/screen" }
    check((try? lan.validate()) != nil && TestDestinationCatalog.Projection(lan).catalog == lan,
          "owner-confirmed nonloopback LAN hostname \(hostname) allowed")
}

struct Carrier: Codable {
    let marker: String
    let testDestinations: TestDestinationCatalog.Projection?
}
for malformed in ["null", "42", "[]", "{}", "\"wrong\"",
                  String(decoding: fixture, as: UTF8.self).replacingOccurrences(of: "reachable", with: "future"),
                  String(decoding: fixture, as: UTF8.self).replacingOccurrences(of: "blocked", with: "future")] {
    let data = Data("{\"marker\":\"preserved\",\"testDestinations\":\(malformed)}".utf8)
    let carrier = try decoder.decode(Carrier.self, from: data)
    check(carrier.marker == "preserved" && carrier.testDestinations?.catalog == nil,
          "malformed optional catalog preserves other synthesized carrier fields")
}
let absent = try decoder.decode(Carrier.self, from: Data("{\"marker\":\"preserved\"}".utf8))
check(absent.testDestinations == nil, "old carrier without field decodes")
let projected = TestDestinationCatalog.Projection(catalog)
for state: Any in ["unavailable", "malformed", "future", NSNull(), 42] {
    var object = encoded
    object["state"] = state
    let data = try JSONSerialization.data(withJSONObject: ["marker": "preserved", "testDestinations": object])
    let carrier = try decoder.decode(Carrier.self, from: data)
    check(carrier.marker == "preserved" && carrier.testDestinations?.catalog == nil,
          "explicit producer failure or invalid state cannot become a confirmed empty catalog")
}
var readyObject = encoded
readyObject["state"] = "ready"
let readyProjection = try decoder.decode(TestDestinationCatalog.Projection.self,
    from: JSONSerialization.data(withJSONObject: readyObject))
check(readyProjection.catalog == catalog, "explicit ready producer state preserves catalog")
let projectionObject = try JSONSerialization.jsonObject(with: encoder.encode(projected)) as! [String: Any]
check(projectionObject["schema"] as? String == catalog.schema && projectionObject["catalog"] == nil,
      "projection emits raw catalog without wrapper")
let nilProjection = try encoder.encode(TestDestinationCatalog.Projection(nil))
check(String(decoding: nilProjection, as: UTF8.self) == "null", "invalid projection encodes null")
var mutatedProjection = projected
mutatedProjection.catalog = duplicate
let mutatedEncoding = try encoder.encode(mutatedProjection)
check(String(decoding: mutatedEncoding, as: UTF8.self) == "null",
      "projection validates again before encoding")
let unknownEnums = String(decoding: fixture, as: UTF8.self).replacingOccurrences(of: "blocked", with: "future")
check(rejects { _ = try decoder.decode(TestDestinationCatalog.self, from: Data(unknownEnums.utf8)) },
      "unknown enum rejected at decoding boundary")

let legacyList = WindowList(macName: "fixture-Mac", windows: [], active: .desktop)
let legacyListObject = try JSONSerialization.jsonObject(with: encoder.encode(legacyList)) as! [String: Any]
check(legacyListObject["testDestinations"] == nil, "old WindowList initializer omits optional carrier")
let decodedLegacyList = try decoder.decode(WindowList.self, from: encoder.encode(legacyList))
check(decodedLegacyList.testDestinations == nil,
      "old WindowList without catalog still decodes")
for malformed in ["null", "42", "[]", "{}", "\"wrong\"", String(decoding: try encoder.encode(duplicate), as: UTF8.self)] {
    let data = Data("{\"macName\":\"fixture-Mac\",\"windows\":[],\"active\":{\"desktop\":{}},\"testDestinations\":\(malformed)}".utf8)
    let list = try decoder.decode(WindowList.self, from: data)
    check(list.macName == "fixture-Mac" && list.active == .desktop && list.testDestinations?.catalog == nil,
          "actual WindowList isolates malformed optional catalog and preserves stream fields")
}
var projectedList = legacyList
projectedList.testDestinations = projected
let listRoundTrip = try decoder.decode(WindowList.self, from: encoder.encode(projectedList))
check(listRoundTrip.testDestinations?.catalog == catalog && listRoundTrip.active == .desktop,
      "actual WindowList carries raw valid projection")

typealias Model = VisionTestDestinations
let peer = Model.PeerBinding(peerID: "fixture-peer", generation: UUID())
let otherPeer = Model.PeerBinding(peerID: "other-peer", generation: UUID())
let dateFormatter = ISO8601DateFormatter()
let reference = dateFormatter.date(from: "2026-10-20T09:00:00Z")!
var now = reference
let freshCatalog = replacingEntry { $0.checkedAt = "2026-10-20T09:00:00Z" }
let freshEntry = freshCatalog.entries[0]
var model = Model(clock: { now })
check(model.catalogStatus == .disconnected, "starts disconnected with no invented entries")
check(!model.observe(freshCatalog, from: peer), "catalog without current binding ignored")
model.bind(peer)
check(model.catalogStatus == .unavailable, "binding alone does not invent destinations")
var empty = freshCatalog
empty.entries = []
model.observe(empty, from: peer)
check(model.catalogStatus == .empty && model.entries.isEmpty, "producer live zero entries remains honestly empty")
model.observe(unsupported, from: peer)
check(model.catalogStatus == .unsupported && model.catalog == nil, "unsupported version discarded")
model.observe(duplicate, from: peer)
check(model.catalogStatus == .invalid && model.entries.isEmpty, "invalid catalog discarded instead of displaying unsafe entries")
model.observe(catalog, from: peer)
check(!model.open(entry, from: peer), "unknown checkedAt cannot execute")
model.observe(freshCatalog, from: peer)
now = reference.addingTimeInterval(45)
check(model.open(freshEntry, from: peer), "exact 45 second boundary accepted")
let expiring = model.selection!
now = reference.addingTimeInterval(45.001)
check(!model.open(freshEntry, from: peer) && !model.isCurrent(expiring), "older than 45 seconds cannot open or remain current")
check(!model.allowsNavigation(to: expiring.url, for: expiring), "navigation rechecks freshness after opening")
model.report(.response(200), for: expiring)
check(model.selection == nil && model.pageStatus == .notOpened, "만료 후 늦은 성공 콜백은 선택을 해제하고 페이지를 되살리지 않는다")
now = reference.addingTimeInterval(-0.001)
check(!model.open(freshEntry, from: peer), "future checkedAt cannot execute even within clock skew")
now = reference
model.close()
let lanCatalog = replacingEntry { $0.url = "https://Macbook.local:8443/screen"; $0.checkedAt = freshEntry.checkedAt }
model.observe(lanCatalog, from: peer)
check(model.open(lanCatalog.entries[0], from: peer), "nonloopback Macbook.local HTTPS opens natively")
for embed in [TestDestinationCatalog.Embed.allowed, .blocked, .unknown] {
    var value = freshCatalog
    value.entries[0].embed = embed
    model.observe(value, from: peer)
    check(model.open(value.entries[0], from: peer), "iframe \(embed.rawValue) is informational for native view")
    check(model.pageStatus == .loading, "host reachability never implies device success")
}
for reachability in [TestDestinationCatalog.Reachability.unreachable, .unknown] {
    var value = freshCatalog
    value.entries[0].reachability = reachability
    model.observe(value, from: peer)
    check(model.selection == nil && !model.open(value.entries[0], from: peer), "\(reachability) cannot execute")
}
model.observe(freshCatalog, from: peer)
for change in ["projectId", "projectLabel", "origin", "owner", "path"] {
    var forged = freshEntry
    switch change {
    case "projectId": forged.projectId = "other-project"
    case "projectLabel": forged.projectLabel = "다른 프로젝트"
    case "origin": forged.url = "https://other.example.test/screen"
    case "owner": forged.owner = "other-owner"
    default: forged.url = "https://example.test/guessed"
    }
    check(!model.open(forged, from: peer), "stale or invented \(change) never executes")
}
check(!model.open(freshEntry, from: otherPeer), "foreign binding cannot open trusted entry")
check(model.open(freshEntry, from: peer), "exact fresh entry opens")
let selected = model.selection!
check(model.allowsNavigation(to: URL(string: "https://EXAMPLE.test:443/next?fixture=1#part")!, for: selected),
      "exact HTTPS origin permits path query and fragment changes")
for url in ["http://example.test/screen", "https://example.test:444/screen", "https://login.example.test/start",
            "https://other.example.test/screen", "https://example.test.evil.test/screen",
            "https://person@example.test/screen", "mailto:fixture@example.test", "about:blank"] {
    check(!model.allowsNavigation(to: URL(string: url)!, for: selected), "unregistered navigation rejected \(url)")
}
check(!model.observe(empty, from: otherPeer) && model.selection == selected, "foreign catalog cannot erase current selection")
for status in [Model.PageStatus.responseReceived(200), .displaying(200), .response(200), .response(503),
               .authenticationDenied, .navigationDenied, .failed] {
    model.report(status, for: selected)
    check(model.pageStatus == status, "device response loading and denial states stay distinct \(status)")
}
let retainedEpoch = model.storageEpoch
model.observe(freshCatalog, from: peer)
check(model.selection == selected && model.storageEpoch == retainedEpoch, "unchanged catalog keeps isolated project login session")
var refreshed = freshCatalog
refreshed.observedAt = "2026-10-20T09:01:00Z"
model.observe(refreshed, from: peer)
check(model.selection == selected, "catalog observation time does not invent an entry freshness update")
now = reference.addingTimeInterval(40)
refreshed.entries[0].checkedAt = "2026-10-20T09:00:40Z"
refreshed.entries[0].embed = .unknown
refreshed.entries[0].reason = "새 관측"
model.report(.displaying(200), for: selected)
model.observe(refreshed, from: peer)
check(model.selection?.id == selected.id && model.pageStatus == .displaying(200) && model.storageEpoch == retainedEpoch,
      "확인 시각과 호환 관측 갱신은 선택 UUID와 페이지 상태 및 로그인 범위를 유지한다")
now = reference.addingTimeInterval(70)
check(model.isCurrent(selected) && model.allowsNavigation(to: selected.url, for: selected),
      "처음 선택한 관측이 만료되어도 최신 카탈로그의 신선한 관측으로 콜백 권한을 확인한다")
model.report(.response(200), for: selected)
check(model.pageStatus == .response(200), "갱신 후 기존 페이지 콜백이 같은 선택에 결과를 반영한다")
refreshed.entries[0].projectLabel = "수정된 프로젝트"
model.observe(refreshed, from: peer)
check(model.selection == nil, "current catalog label replacement invalidates open selection")
model.report(.response(200), for: selected)
check(model.pageStatus == .notOpened, "old page callback cannot revive replaced selection")
now = reference
for change in ["id", "projectId", "projectLabel", "url", "owner", "redirectOrigins", "stale", "unreachable", "unknown"] {
    model.observe(freshCatalog, from: peer)
    model.open(freshEntry, from: peer)
    let previous = model.selection!
    var changed = freshCatalog
    switch change {
    case "id": changed.entries[0].id = "다른 항목"
    case "projectId": changed.entries[0].projectId = "다른 프로젝트"
    case "projectLabel": changed.entries[0].projectLabel = "다른 이름"
    case "url": changed.entries[0].url = "https://example.test/changed"
    case "owner": changed.entries[0].owner = "다른 담당"
    case "redirectOrigins": changed.entries[0].redirectOrigins = ["https://login.example.test"]
    case "stale": changed.entries[0].checkedAt = "2026-10-20T08:59:00Z"
    case "unreachable": changed.entries[0].reachability = .unreachable
    default: changed.entries[0].reachability = .unknown
    }
    model.observe(changed, from: peer)
    model.report(.response(200), for: previous)
    check(model.selection == nil && model.pageStatus == .notOpened && !model.isCurrent(previous),
          "실제 권한 변경이나 유효하지 않은 관측은 기존 페이지 선택을 해제한다: \(change)")
}
var redirectCatalog = freshCatalog
redirectCatalog.entries[0].redirectOrigins = redirects
model.observe(redirectCatalog, from: peer)
check(model.open(redirectCatalog.entries[0], from: peer), "registered redirect entry opens")
let redirectSelection = model.selection!
for url in ["https://login.example.test/authorize?fixture=1", "https://Macbook.local:8443/callback",
            "https://example.test/return"] {
    check(model.allowsNavigation(to: URL(string: url)!, for: redirectSelection), "registered exact redirect permits \(url)")
}
for url in ["https://sub.login.example.test/authorize", "https://login.example.test:444/start",
            "http://login.example.test/start", "https://login.example.test.evil.test/start"] {
    check(!model.allowsNavigation(to: URL(string: url)!, for: redirectSelection), "registered origin does not grant \(url)")
}
model.observe(freshCatalog, from: peer)
check(!model.allowsNavigation(to: redirectSelection.url, for: redirectSelection), "redirect registration removal revokes existing selection")
let httpCatalog = replacingEntry { $0.url = "http://example.test:8080/screen"; $0.checkedAt = freshEntry.checkedAt }
model.observe(httpCatalog, from: peer)
check(!model.open(httpCatalog.entries[0], from: peer), "shared legacy HTTP entry never executes in HTTPS native viewer")
model.observe(freshCatalog, from: peer)
model.open(freshEntry, from: peer)
let oldView = model.selection!
model.close()
check(model.storageEpoch == retainedEpoch && model.open(freshEntry, from: peer), "closing viewer preserves paired project login store")
check(model.selection?.id != oldView.id, "reopening creates new callback identity while retaining project store")
model.report(.failed, for: oldView)
check(model.pageStatus == .loading, "previous view callback cannot alter reopened page")
let beforeInvalid = model.storageEpoch
model.observe(duplicate, from: peer)
check(model.catalog == nil && model.selection == nil && model.storageEpoch != beforeInvalid,
      "invalid catalog clears selection and project store authority")
model.observe(freshCatalog, from: peer)
model.open(freshEntry, from: peer)
let beforeUnavailable = model.storageEpoch
model.observe(nil, from: peer)
check(model.catalogStatus == .unavailable && model.selection == nil && model.storageEpoch != beforeUnavailable,
      "missing or malformed projection clears former project store authority")
model.observe(freshCatalog, from: peer)
model.open(freshEntry, from: peer)
let oldGenerationSelection = model.selection!
let nextGeneration = Model.PeerBinding(peerID: peer.peerID, generation: UUID())
let beforeReconnect = model.storageEpoch
model.bind(nextGeneration)
check(model.catalog == nil && model.selection == nil && model.storageEpoch != beforeReconnect,
      "same peer reconnect clears catalog selection and project store authority")
check(!model.observe(freshCatalog, from: peer), "old generation catalog cannot cross reconnect")
check(!model.allowsNavigation(to: oldGenerationSelection.url, for: oldGenerationSelection), "old generation loses navigation authority")
model.observe(freshCatalog, from: nextGeneration)
model.open(freshEntry, from: nextGeneration)
let beforeDisconnect = model.storageEpoch
model.bind(nil)
check(model.catalogStatus == .disconnected && model.catalog == nil && model.selection == nil && model.storageEpoch != beforeDisconnect,
      "disconnect clears remote catalog viewer and login scope")
model.bind(Model.PeerBinding(peerID: "  ", generation: UUID()))
check(model.binding == nil, "empty peer identity cannot authorize catalog")

runAdapterChecks(catalog: freshCatalog, now: reference)
runWebViewChecks(catalog: freshCatalog, now: reference)
print("\(checks) checks, \(failures) failures")
if failures != 0 { exit(1) }
