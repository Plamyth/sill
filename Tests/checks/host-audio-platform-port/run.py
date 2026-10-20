#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import tempfile

here = Path(__file__).resolve().parent
root = here.parents[2]
sources = sorted((root / 'Sources').rglob('*.swift')) + [root / 'Package.swift', here / 'Checks.swift', Path(__file__)]

def manifest():
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}

before = manifest()
print('INPUT_SHA256', hashlib.sha256(json.dumps(before, sort_keys=True).encode()).hexdigest(), flush=True)
print('SWIFTC', subprocess.check_output(['xcrun', 'swiftc', '--version'], text=True).strip(), flush=True)
try:
    subprocess.run(['swift', 'build', '--jobs', '2'], cwd=root, check=True)
    build = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=root, text=True).strip())
    objects = sorted((build / 'SillHostCore.build').glob('*.o')) + sorted((build / 'StreamProtocol.build').glob('*.o'))
    assert list((build / 'SillHostCore.build').glob('HostAudioPrivacy.swift.o'))
    assert list((build / 'SillHostCore.build').glob('HostSentryPlatform.swift.o'))
    with tempfile.TemporaryDirectory(prefix='inactive-platform-', dir=build) as temporary:
        binary = Path(temporary) / 'checks'
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-package-name', 'Sill',
            '-target', platform.machine() + '-apple-macosx14.0', '-I', str(build / 'Modules'),
            '-module-cache-path', str(Path(temporary) / 'cache'), str(here / 'Checks.swift'),
            *map(str, objects), '-o', str(binary)], cwd=root, check=True)
        subprocess.run([str(binary)], cwd=root, check=True, timeout=30)
finally:
    assert manifest() == before, '검사 중 소스가 변경되었습니다.'
    print('SOURCE_UNCHANGED', True, flush=True)
