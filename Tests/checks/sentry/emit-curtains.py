import argparse
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
output = args.output.resolve()
if output.exists():
    raise SystemExit('Preserve the previous extraction attempt')


def block(text, marker):
    start = text.index(marker)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


platform = (root / 'Sources/SillHost/HostSentryPlatform.swift').read_text()
coordinator = (root / 'Sources/SillHost/StreamCoordinator.swift').read_text()
markers = ['func engage()', 'private var isProtected:', 'private func invalidate(', 'private func observeChanges()',
           'private func recoverFailedRelease(', 'private var curtainMessage:', 'func restoreCurtains()']
parts = [block(platform, marker) for marker in markers]
text = (root / 'Tests/checks/sentry/CurtainChecks.swift').read_text()
text = text.replace('__PRODUCTION_LIFECYCLE__', '\n\n'.join(parts))
text = text.replace('HostSentryPlatform', 'CurtainPlatformFixture')
text = text.replace('NSWorkspace', 'FixtureWorkspace').replace('NSApplication', 'FixtureApplication')
text = text.replace('DistributedNotificationCenter', 'FixtureDistributedCenter')
changed = block(coordinator, 'platform.changed =').replace('sentry', 'owner')
text = text.replace('__PRODUCTION_CHANGED__', changed)
start = coordinator.index('surfaces: .init(')
end = coordinator.index(',\n            audioReady:', start)
surfaces = coordinator[start:end].removeprefix('surfaces: ')
text = text.replace('__PRODUCTION_SURFACES__', surfaces)
output.mkdir(parents=True)
(output / 'CurtainChecks.swift').write_text(text)
native_markers = ['private struct Curtain {', 'private func makeCurtain(']
native_parts = {marker: block(platform, marker) for marker in native_markers}
level = next(line.strip() for line in platform.splitlines() if 'private static let curtainLevel =' in line)
native = (root / 'Tests/checks/sentry/NativePanelChecks.swift').read_text()
native = native.replace('__PRODUCTION_CURTAIN_TYPE__', native_parts[native_markers[0]])
native = native.replace('__PRODUCTION_CURTAIN_LEVEL__', level)
native = native.replace('__PRODUCTION_MAKE_CURTAIN__', native_parts[native_markers[1]])
(output / 'NativePanelChecks.swift').write_text(native)
(output / 'manifest.json').write_text(json.dumps({
    'scope': 'Actual owner, extracted platform lifecycle, timer and production callback. Injected window/HID/notification boundaries only.',
    'platformBodiesSHA256': {marker: hashlib.sha256(block(platform, marker).encode()).hexdigest() for marker in markers},
    'changedSHA256': hashlib.sha256(changed.encode()).hexdigest(),
    'surfacesSHA256': hashlib.sha256(surfaces.encode()).hexdigest(),
    'emittedSHA256': hashlib.sha256(text.encode()).hexdigest(),
    'nativePanelBodiesSHA256': {marker: hashlib.sha256(value.encode()).hexdigest() for marker, value in native_parts.items()},
    'nativePanelLevelSHA256': hashlib.sha256(level.encode()).hexdigest(),
    'nativePanelEmittedSHA256': hashlib.sha256(native.encode()).hexdigest()
}, indent=2) + '\n')

main = (root / 'Tests/checks/sentry/Main.swift').read_text()
anchor = '    @MainActor static func main() {'
assert main.count(anchor) == 1
main = main.replace(anchor, anchor + '\n        if CommandLine.arguments.contains("--curtains") { curtainRecoveryChecks(); return }\n        if CommandLine.arguments.contains("--refresh") { curtainRefreshChecks(); return }')
(output / 'Main.swift').write_text(main)
