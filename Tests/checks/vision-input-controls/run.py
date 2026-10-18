import json
from pathlib import Path
import re
import subprocess
import sys

from extract import fixture


def main():
    root, output = [Path(p).resolve() for p in sys.argv[1:3]]
    if output == root or root in output.parents or (output.exists() and any(output.iterdir())):
        raise SystemExit('use a fresh output outside source')
    output.mkdir(parents=True, exist_ok=True)
    files, extraction = fixture()
    generated = output / 'generated'
    for name, contents in files.items():
        path = generated / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
    record = {'scope': 'Existing actual input adapter extraction and controls with inert Network/SwiftUI; no device or host delivery',
              'extractionSHA256': extraction, 'commands': [], 'exitCode': 2}
    base = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-package-name', 'sill', '-module-cache-path', str(output / 'cache')]

    def run(command, label):
        result = subprocess.run(command, capture_output=True, text=True, timeout=90)
        log = result.stdout + result.stderr
        (output / (label + '.log')).write_text(log)
        record['commands'].append({'label': label, 'exitCode': result.returncode})
        if result.returncode:
            raise RuntimeError(label + '\n' + log[-6000:])
        return log

    try:
        groups = [('Network', [generated / 'Network.swift']), ('SwiftUI', [generated / 'SwiftUI.swift']),
                  ('StreamProtocol', sorted((generated / 'Sources/StreamProtocol').glob('*.swift')))]
        for name, sources in groups:
            run(base + ['-parse-as-library', '-emit-module', '-emit-object', '-whole-module-optimization', '-module-name', name] +
                list(map(str, sources)) + ['-emit-module-path', str(output / (name + '.swiftmodule')), '-o', str(output / (name + '.o'))], 'compile-' + name)
        names = ['Client.swift', 'iOSClient/SessionLink.swift', 'iOSClient/KeyChords.swift', 'Sources/SillHost/KeyStrokes.swift',
                 'visionOSClient/VisionPointer.swift', 'visionOSClient/VisionInputSession.swift', 'visionOSClient/VisionInputDebt.swift',
                 'visionOSClient/VisionTextDraft.swift', 'visionOSClient/VisionPresentation.swift', 'visionOSClient/VisionRemoteKey.swift',
                 'Tests/checks/vision-input-controls/SourceInputFence.swift', 'main.swift']
        run(base + ['-I', str(output)] + [str(generated / name) for name in names] +
            [str(output / (name + '.o')) for name, _ in groups] + ['-o', str(output / 'checks')], 'compile-checks')
        log = run([str(output / 'checks')], 'runtime-checks')
        record['assertions'] = int(re.search(r'RESULT_ASSERTIONS (\d+)', log)[1])
        record['generatedInputsUnchanged'] = all((generated / n).read_text() == value for n, value in files.items())
        record['exitCode'] = 0 if record['generatedInputsUnchanged'] else 2
    except Exception as error:
        record['error'] = str(error)
    (output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record))
    return record['exitCode']


if __name__ == '__main__':
    sys.exit(main())
