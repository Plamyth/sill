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

typealias Model = VisionTestDestinations
let peer = Model.PeerBinding(peerID: "fixture-peer", generation: UUID())
let otherPeer = Model.PeerBinding(peerID: "other-peer", generation: UUID())
var model = Model()
check(model.catalogStatus == .disconnected, "starts disconnected with no invented entries")
check(!model.observe(catalog, from: peer), "catalog without current binding ignored")
model.bind(peer)
check(model.catalogStatus == .unavailable, "binding alone does not create destinations")
var empty = catalog
empty.entries = []
model.observe(empty, from: peer)
check(model.catalogStatus == .empty && model.entries.isEmpty, "zero live entries honestly empty")
model.observe(unsupported, from: peer)
check(model.catalogStatus == .unsupported && !model.open(entry, from: peer), "unsupported version never opens")
model.observe(duplicate, from: peer)
check(model.catalogStatus == .invalid && !model.open(entry, from: peer), "duplicate identity invalidates catalog")
let lanCatalog = replacingEntry { $0.url = "http://Macbook.local:8080/screen" }
model.observe(lanCatalog, from: peer)
check(model.open(lanCatalog.entries[0], from: peer), "confirmed Bonjour LAN entry opens natively")
model.close()
for embed in [TestDestinationCatalog.Embed.allowed, .blocked, .unknown] {
    let value = replacingEntry { $0.embed = embed }
    model.observe(value, from: peer)
    check(model.open(value.entries[0], from: peer), "iframe \(embed.rawValue) does not gate native top-level")
    check(model.pageStatus == .loading, "host reachability is not a client success")
}
for reachability in [TestDestinationCatalog.Reachability.unreachable, .unknown] {
    let value = replacingEntry { $0.reachability = reachability }
    model.observe(value, from: peer)
    check(model.selection == nil && !model.open(value.entries[0], from: peer), "\(reachability) cannot open")
}
model.observe(catalog, from: peer)
var invented = entry
invented.url = "https://example.test/guessed"
check(!model.open(invented, from: peer), "matching id with invented URL rejected")
invented = entry
invented.owner = "different-owner"
check(!model.open(invented, from: peer), "matching URL with changed owner rejected")
check(!model.open(entry, from: otherPeer), "other binding cannot open trusted entry")
check(model.open(entry, from: peer), "exact current entry opens")
let selected = model.selection!
check(model.allowsNavigation(to: URL(string: "https://EXAMPLE.test:443/next?fixture=1#part")!, for: selected),
      "same origin accepts paths queries fragments and default port")
for url in ["http://example.test/screen", "https://example.test:444/screen",
            "https://other.example.test/screen", "https://example.test.evil.test/screen",
            "https://person@example.test/screen", "mailto:fixture@example.test", "about:blank"] {
    check(!model.allowsNavigation(to: URL(string: url)!, for: selected), "navigation rejects \(url)")
}
check(!model.observe(empty, from: otherPeer) && model.selection == selected, "late foreign catalog cannot erase current selection")
model.report(.response(503), for: selected)
check(model.pageStatus == .response(503), "actual client HTTP error preserved independently")
model.report(.responseReceived(200), for: selected)
check(model.pageStatus == .responseReceived(200), "received device response is not finished display")
model.report(.displaying(200), for: selected)
check(model.pageStatus == .displaying(200), "commit is distinct from completed load")
model.report(.authenticationDenied, for: selected)
check(model.pageStatus == .authenticationDenied, "authentication denial stays distinct from host observation")
model.observe(catalog, from: peer)
check(model.selection == selected, "unchanged catalog keeps view and isolated session")
var newer = catalog
newer.observedAt = "2026-10-20T09:01:00Z"
model.observe(newer, from: peer)
check(model.selection == selected, "observation refresh preserves exact unchanged entry")
newer.entries[0].checkedAt = "2026-10-20T09:01:00Z"
model.observe(newer, from: peer)
check(model.selection == nil, "changed entry invalidates selection")
model.report(.response(200), for: selected)
check(model.pageStatus == .notOpened, "late page callback cannot revive invalidated view")

let httpCatalog = replacingEntry { $0.url = "http://example.test:8080/screen" }
model.observe(httpCatalog, from: peer)
check(model.open(httpCatalog.entries[0], from: peer), "owner-confirmed HTTP has no invented private-only policy")
let httpSelection = model.selection!
check(model.allowsNavigation(to: URL(string: "http://example.test:8080/next")!, for: httpSelection), "HTTP same origin allowed")
check(!model.allowsNavigation(to: URL(string: "http://example.test/next")!, for: httpSelection), "HTTP different port denied")
model.close()
check(model.open(httpCatalog.entries[0], from: peer) && model.selection?.id != httpSelection.id,
      "new view gets a distinct session identity")
let replacement = model.selection!
model.report(.failed, for: httpSelection)
check(model.pageStatus == .loading, "older view callback cannot change new view")
let nextGeneration = Model.PeerBinding(peerID: peer.peerID, generation: UUID())
model.bind(nextGeneration)
check(model.catalog == nil && model.selection == nil && model.pageStatus == .notOpened,
      "same peer reconnect clears catalog and selection by generation")
check(!model.observe(catalog, from: peer), "old generation catalog cannot cross reconnect")
check(!model.allowsNavigation(to: replacement.url, for: replacement), "old generation loses navigation authority")
model.observe(catalog, from: nextGeneration)
model.open(entry, from: nextGeneration)
model.bind(nil)
check(model.catalogStatus == .disconnected && model.catalog == nil && model.selection == nil,
      "disconnect clears all remote viewer state")
model.bind(Model.PeerBinding(peerID: "  ", generation: UUID()))
check(model.binding == nil, "empty peer identity cannot authorize catalog")

print("\(checks) checks, \(failures) failures")
if failures != 0 { exit(1) }
