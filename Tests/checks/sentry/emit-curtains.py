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
           'private func recoverFailedRelease(', 'private var curtainMessage:', 'func restoreCurtains()',
           'private func refreshActiveAuthenticationInput(']
parts = [block(platform, marker) for marker in markers]
text = (root / 'Tests/checks/sentry/CurtainChecks.swift').read_text()
text = text.replace('__PRODUCTION_LIFECYCLE__', '\n\n'.join(parts))
text = text.replace('HostSentryPlatform', 'CurtainPlatformFixture')
text = text.replace('NSRunningApplication', 'FixtureRunningApplication')
text = text.replace('NSWorkspace', 'FixtureWorkspace').replace('NSApplication', 'FixtureApplication')
text = text.replace('DistributedNotificationCenter', 'FixtureDistributedCenter')
changed = block(coordinator, 'platform.changed =').replace('sentry', 'owner')
text = text.replace('__PRODUCTION_CHANGED__', changed)
start = coordinator.index('surfaces: .init(')
end = coordinator.index(',\n            prepareRelease:', start)
surfaces = coordinator[start:end].removeprefix('surfaces: ')
text = text.replace('__PRODUCTION_SURFACES__', surfaces)
output.mkdir(parents=True)
(output / 'CurtainChecks.swift').write_text(text)
native_markers = ['private struct Curtain {', 'private func makeCurtain(']
native_markers += ['private var isProtected:', 'private func invalidate(', 'private var curtainMessage:', 'private func updateCurtainText()', 'let timer = Timer(timeInterval: 0.1']
native_parts = {marker: block(platform, marker) for marker in native_markers}
level = next(line.strip() for line in platform.splitlines() if 'private static let curtainLevel =' in line)
native = (root / 'Tests/checks/sentry/NativePanelChecks.swift').read_text()
native = native.replace('__PRODUCTION_CURTAIN_TYPE__', native_parts[native_markers[0]])
native = native.replace('__PRODUCTION_CURTAIN_LEVEL__', level)
native = native.replace('__PRODUCTION_MAKE_CURTAIN__', native_parts[native_markers[1]])
native = native.replace('__PRODUCTION_PANEL_REFRESH__', '\n'.join(native_parts[m] for m in native_markers[2:6]))
native = native.replace('__PRODUCTION_REFRESH_TIMER__', native_parts[native_markers[6]])
(output / 'NativePanelChecks.swift').write_text(native)
cursor_markers = ['private func curtainsAreEffective()', 'private func visibleReturnButton(', 'private static func isSystemCursorWindow(']
cursor_parts = {marker: block(platform, marker) for marker in cursor_markers}
cursor = (root / 'Tests/checks/sentry/CursorChecks.swift').read_text()
cursor = cursor.replace('__PRODUCTION_CURSOR_BOUNDARY__', '\n\n'.join(cursor_parts.values()))
(output / 'CursorChecks.swift').write_text(cursor)
(output / 'manifest.json').write_text(json.dumps({
    'scope': 'Actual owner, extracted platform lifecycle, timer and production callback. Injected window/HID/notification boundaries only.',
    'platformBodiesSHA256': {marker: hashlib.sha256(block(platform, marker).encode()).hexdigest() for marker in markers},
    'changedSHA256': hashlib.sha256(changed.encode()).hexdigest(),
    'surfacesSHA256': hashlib.sha256(surfaces.encode()).hexdigest(),
    'emittedSHA256': hashlib.sha256(text.encode()).hexdigest(),
    'nativePanelBodiesSHA256': {marker: hashlib.sha256(value.encode()).hexdigest() for marker, value in native_parts.items()},
    'nativePanelLevelSHA256': hashlib.sha256(level.encode()).hexdigest(),
    'nativePanelEmittedSHA256': hashlib.sha256(native.encode()).hexdigest(),
    'cursorBoundaryBodiesSHA256': {marker: hashlib.sha256(value.encode()).hexdigest() for marker, value in cursor_parts.items()},
    'cursorBoundaryEmittedSHA256': hashlib.sha256(cursor.encode()).hexdigest()
}, indent=2) + '\n')

main = (root / 'Tests/checks/sentry/Main.swift').read_text()
anchor = '    @MainActor static func main() {'
assert main.count(anchor) == 1
main = main.replace(anchor, anchor + '\n        if CommandLine.arguments.contains("--curtains") { curtainRecoveryChecks(); return }\n        if CommandLine.arguments.contains("--refresh") { curtainRefreshChecks(); return }\n        if CommandLine.arguments.contains("--cursor") { cursorWindowChecks(); return }')
(output / 'Main.swift').write_text(main)
