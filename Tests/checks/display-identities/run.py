#!/usr/bin/env python3
"""Pure production catalog projection plus SDK typecheck. No display discovery or capture."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def block(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


root = Path(sys.argv[1]).resolve()
paths = ['Sources/StreamProtocol/Switcher.swift', 'Sources/SillHost/WindowCatalog.swift',
         'Sources/SillHost/DisplayInventory.swift', 'Tests/checks/display-identities/run.py']
hashes = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in paths}
switcher = (root / paths[0]).read_text()
catalog = (root / paths[1]).read_text()
inventory = (root / paths[2]).read_text().replace('import StreamProtocol', '')
source = '''import Foundation
import CoreFoundation
struct SCDisplay { let displayID: UInt32; var width = 1920; var height = 1080; var frame = "fixture-frame" }
struct NSDeviceDescriptionKey: Hashable { let value: String; init(_ value: String) { self.value = value } }
struct NSScreen { static var screens: [Self] = []; var deviceDescription: [NSDeviceDescriptionKey: NSNumber] = [:]; var localizedName = "Fixture" }
enum VirtualStage { static let vendorID: UInt32 = 777 }
enum ExtendedDesktop { static let name = "가상 확장" }
var physical: [UInt32] = [107, 209]
var identities: [UInt32: String] = [107: "11111111-1111-1111-1111-111111111111", 209: "22222222-2222-2222-2222-222222222222"]
func CGDisplayIsActive(_ id: UInt32) -> UInt32 { 1 }
func CGDisplayVendorNumber(_ id: UInt32) -> UInt32 { id == 901 ? VirtualStage.vendorID : 42 }
func CGMainDisplayID() -> UInt32 { physical.first ?? 0 }
func CGDisplayCreateUUIDFromDisplayID(_ id: UInt32) -> Unmanaged<CFUUID>? {
    guard let value = identities[id], let uuid = CFUUIDCreateFromString(nil, value as CFString) else { return nil }
    return Unmanaged.passRetained(uuid)
}
'''
source += block(switcher, 'public struct DisplayInfo:') + '\n'
source += '''struct DisplaySelection { let displayID: UInt32; let inventoryID: UUID }
'''
source += inventory + '\nfinal class CatalogFixture {\n'
source += '''var displays: [SCDisplay] = []
var extendedDesktopID: UInt32? = 901
var displayInventory = DisplayInventory()
var onDisplaysChanged: (() -> Void)?
static func physicalDisplayIDs() -> [UInt32] { physical }
func update(_ candidates: [SCDisplay]) { updateDisplays(candidates) }
'''
source += block(catalog, 'private func updateDisplays(') + '\n' + block(catalog, 'static func admitsDisplay(') + '\n}\n'
source += '''
var assertions = 0
func check(_ pass: Bool, _ label: String) { assertions += 1; precondition(pass, label) }
let fixture = CatalogFixture()
fixture.update([SCDisplay(displayID: 107), SCDisplay(displayID: 209), SCDisplay(displayID: 901), SCDisplay(displayID: 999)])
check(fixture.displayInventory.infos.count == 3, "unsupported OS virtual display is excluded")
let before = fixture.displayInventory.infos
check(before[0].stableIdentity == "cgdisplay:11111111-1111-1111-1111-111111111111", "physical uses OS UUID")
check(before[2].stableIdentity == nil, "owned virtual display has no persistence claim")
physical = [107, 307]; identities[307] = identities[209]
fixture.update([SCDisplay(displayID: 107), SCDisplay(displayID: 307)])
check(fixture.displayInventory.infos[1].stableIdentity == before[1].stableIdentity, "numeric reassignment preserves physical UUID")
physical.append(409); identities[409] = identities[307]
fixture.update(physical.map { SCDisplay(displayID: $0) })
check(fixture.displayInventory.infos.filter { $0.stableIdentity == nil }.count == 2, "duplicate physical UUIDs are withheld")
identities[307] = nil; identities[409] = nil
fixture.update(physical.map { SCDisplay(displayID: $0) })
check(fixture.displayInventory.infos[1].stableIdentity == nil, "missing OS UUID has no fallback to number or name")
let legacy = Data("{\\"id\\":209,\\"name\\":\\"B\\",\\"width\\":1920,\\"height\\":1080,\\"isMain\\":false}".utf8)
check(try! JSONDecoder().decode(DisplayInfo.self, from: legacy).stableIdentity == nil, "old wire decodes absent optional")
check(try! JSONDecoder().decode(DisplayInfo.self, from: JSONEncoder().encode(before[0])) == before[0], "new wire round trips")
print("RESULT_ASSERTIONS \\(assertions) FAILURES 0")
'''
sdk = '''import Foundation
import CoreGraphics
import ColorSync
func sdkIdentity(_ id: CGDirectDisplayID) -> String? {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
    return "cgdisplay:" + (CFUUIDCreateString(nil, uuid) as String).lowercased()
}
'''
record = {'scope': 'production DisplayInfo, DisplayInventory and updateDisplays with inert OS inputs; actual SDK typecheck only',
          'sourceSHA256': hashes, 'commands': []}
with tempfile.TemporaryDirectory(prefix='display-identities-') as temp:
    path = Path(temp)
    (path / 'main.swift').write_text(source)
    (path / 'sdk.swift').write_text(sdk)
    for label, command in [('sdk', ['xcrun', 'swiftc', '-typecheck', str(path / 'sdk.swift')]),
                           ('compile', ['xcrun', 'swiftc', '-module-cache-path', str(path / 'cache'), str(path / 'main.swift'), '-o', str(path / 'checks')]),
                           ('runtime', [str(path / 'checks')])]:
        result = subprocess.run(command, capture_output=True, text=True, timeout=90)
        record['commands'].append({'label': label, 'exitCode': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr})
        if result.returncode:
            break
record['sourceUnchanged'] = all(hashlib.sha256((root / name).read_bytes()).hexdigest() == value for name, value in hashes.items())
record['outputCleaned'] = not path.exists()
print(json.dumps(record, ensure_ascii=False))
sys.exit(0 if record['sourceUnchanged'] and record['commands'][-1]['label'] == 'runtime' and record['commands'][-1]['exitCode'] == 0 else 1)
