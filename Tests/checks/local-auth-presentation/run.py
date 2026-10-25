#!/usr/bin/env python3
"""Run inert screen selection and typecheck native presentation without opening UI."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
presenter = root / 'Sources/SillHost/LocalAuthenticationPresentation.swift'
authentication = root / 'Sources/SillHost/LocalAudioReturn.swift'
checks = Path(__file__).with_name('ScreenChecks.swift')
paths = [presenter, authentication, checks, Path(__file__).resolve()]
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
source = presenter.read_text()
begin = source.index('    static func builtinScreen(')
end = source.index('\n    func begin(', begin)
selection = '@MainActor final class LocalAuthenticationPresentation {\n' + """
    private var window: NSWindow?
    private var operationID: UUID?
    private static weak var registeredOwner: LocalAuthenticationPresentation?
    init(window: NSWindow, operationID: UUID) {
        self.window = window; self.operationID = operationID; Self.registeredOwner = self
    }
""" + source[begin:end] + '\n}\n'
program = selection + checks.read_text()
print('screen_selection_sha256=' + hashlib.sha256(program.encode()).hexdigest(), flush=True)
result = subprocess.run(['/usr/bin/swift', '-swift-version', '5', '-'], input=program, text=True, timeout=60)
if result.returncode:
    sys.exit(result.returncode)
local = authentication.read_text()
begin = local.index('@MainActor\nfinal class LocalAudioAuthentication')
end = local.index('@MainActor\nfinal class LocalAudioJournal', begin)
sdk_input = source + '\nimport LocalAuthentication\nimport LocalAuthenticationEmbeddedUI\n' + local[begin:end] + '''
func sdkRightAnchor(_ right: LARight, _ window: NSWindow) {
    right.authorize(localizedReason: "SDK typecheck only", in: window) { _ in }
}
'''
sdk = subprocess.check_output(['/usr/bin/xcrun', '--show-sdk-path'], text=True).strip()
cache = root / '.build/local-auth-presentation-module-cache'
command = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-typecheck', '-parse-as-library',
           '-sdk', sdk, '-target', 'arm64-apple-macosx14.0', '-module-cache-path', str(cache), '-']
print('SDK_TYPECHECK_ONLY ' + sdk, flush=True)
result = subprocess.run(command, input=sdk_input, text=True, timeout=120)
unchanged = all(hashlib.sha256((root / name).read_bytes()).hexdigest() == sha for name, sha in hashes.items())
print(json.dumps({'sourceSHA256': hashes, 'sourceUnchanged': unchanged, 'sdk': sdk,
    'sdkInputSHA256': hashlib.sha256(sdk_input.encode()).hexdigest(), 'sdkTypecheckExit': result.returncode,
    'actualAuthenticationUIHALInputActions': 0, 'boundary': 'inert selector only; AppKit and LARight are typechecked, never executed'}))
sys.exit(result.returncode if unchanged else 2)
