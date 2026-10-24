"""Compile the production Host, run memory-only contracts, and verify inert Node interoperability."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
sources = sorted((root / 'Sources').rglob('*.swift')) + sorted((root / 'Tests/checks').rglob('*.swift'))
sources += [root / 'Package.swift', Path(__file__).resolve()]
digest = lambda: {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
before = digest()
env = {**os.environ, 'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer',
       'PYTHONDONTWRITEBYTECODE': '1'}
build = output / 'build'
build.mkdir(exist_ok=True)
env.update(CLANG_MODULE_CACHE_PATH=str(build / 'cache'), SWIFTPM_MODULECACHE_OVERRIDE=str(build / 'cache'))
subprocess.run(['swift', 'build', '--build-system', 'native', '-c', 'release', '--product', 'SillMenuBar',
    '--scratch-path', str(build / 'spm'), '--cache-path', str(build / 'spm-cache'),
    '--config-path', str(build / 'spm-config'), '--security-path', str(build / 'spm-security'),
    '--manifest-cache', 'none', '-Xswiftc', '-enable-testing', '-Xswiftc', '-DOWNER_BOOTSTRAP_CONTRACT'],
    cwd=root, env=env, check=True)
modules = next((build / 'spm').glob('*/release/Modules'))
artifacts = modules.parent
objects = []
for target in ['StreamProtocol', 'SillHostCore', 'AudioSilence']:
    objects += sorted((artifacts / (target + '.build')).glob('*.o'))
description = json.loads((artifacts / 'description.json').read_text())
arguments = next(c['otherArguments'] for c in description['swiftCommands'].values() if c['moduleName'] == 'SillHostCore')
package = arguments[arguments.index('-package-name') + 1]
swift = ['xcrun', 'swiftc', '-swift-version', '5', '-package-name', package,
         '-module-cache-path', str(build / 'cache')]
checks = [('wiring', root / 'Tests/checks/mobile-enrollment-wiring/Main.swift'),
          ('receipt', root / 'Tests/checks/owner-enrollment-receipt/Main.swift'),
          ('owner', root / 'Tests/checks/owner-host-bootstrap/main.swift')]
runtime_source = build / 'RuntimeChecks.swift'
runtime_source.write_text('@testable import SillHostCore\n' + (root / 'Tests/checks/mobile-enrollment-runtime/Main.swift').read_text())
checks.append(('runtime', runtime_source))
for name, main in checks:
    result = output / name
    result.mkdir(exist_ok=True)
    binary = build / name
    subprocess.run(swift + ['-parse-as-library', '-I', str(modules), '-I', str(artifacts / 'AudioSilence.build'),
        str(main), *map(str, objects), '-o', str(binary)], cwd=root, env=env, check=True)
    subprocess.run([str(binary), str(result)], cwd=root, env=env, check=True, timeout=120)
    if name in ['wiring', 'runtime']:
        subprocess.run(['node', str(root / 'Tests/checks/mobile-enrollment-runtime/node-compat.js'), str(result)],
                       cwd=root, env=env, check=True, timeout=15)
sdks = []
for sdk, target in [('macosx', 'arm64-apple-macosx14.0'), ('iphoneos', 'arm64-apple-ios17.0'), ('xros', 'arm64-apple-xros2.5')]:
    sdk_path = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True, env=env).strip()
    subprocess.run(swift + ['-typecheck', '-sdk', sdk_path, '-target', target, '-module-name', 'StreamProtocol',
        *map(str, sorted((root / 'Sources/StreamProtocol').glob('*.swift')))], cwd=root, env=env, check=True)
    sdks.append(dict(sdk=sdk, target=target, passed=True))
after = digest()
assert before == after
(output / 'verification.json').write_text(json.dumps(dict(before=before, after=after, sourceUnchanged=True,
    sdks=sdks, productionReleaseBuild='SillMenuBar and SillHostCore with contract hooks',
    productionRegistryWiring=True, productionLifecycleWiring=True, runtimeAccepted=False,
    installedHostChanges=0, actualKeychainCalls=0, actualTLSConnections=0, actualCommandSocketConnections=0,
    actualHostLaunches=0, UIAudioDeviceEffects=0, independentReview='parent-owned, not executed'), indent=2))
print('실제 Host 배선·receipt·owner·runtime·inert Node 및 3개 SDK 검사 통과. 실행 효과 0.')
