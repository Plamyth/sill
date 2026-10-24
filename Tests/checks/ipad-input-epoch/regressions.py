"""기존 Vision·presentation 검사를 메모리 Network 어댑터로 재사용한다."""
import hashlib
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    suite, label, modules = sys.argv[1:4]
    modules = Path(modules).resolve()
    out = ROOT / '.build/checks/ipad-input-epoch' / label
    out.mkdir(parents=True, exist_ok=True)
    if suite == 'vision':
        extractor = load('vision_extract', ROOT / 'Tests/checks/vision-input-controls/extract.py')
        files, manifest = extractor.fixture()
        sources = ['Client.swift', 'iOSClient/SessionLink.swift', 'iOSClient/KeyChords.swift', 'Sources/SillHost/KeyStrokes.swift',
                   'visionOSClient/VisionPointer.swift', 'visionOSClient/VisionInputSession.swift', 'visionOSClient/VisionInputDebt.swift',
                   'visionOSClient/VisionPresentation.swift', 'visionOSClient/VisionTextDraft.swift', 'visionOSClient/VisionRemoteKey.swift',
                   'Tests/checks/vision-input-controls/SourceInputFence.swift', 'main.swift']
    else:
        extractor = load('presentation_extract', ROOT / 'Tests/checks/presentation-epoch/extract.py')
        files, manifest = extractor.fixture(ROOT)
        original_main = files['main.swift']
        files['main.swift'] = (original_main[:original_main.index('let host = MediaHost()')]
                              + original_main[original_main.index('let display = EpochDisplay()'):original_main.index('let gatedHost = GeometryHost()')]
                              + 'print("RESULT_ASSERTIONS \\(assertions)")\n')
        sources = ['Client.swift', 'Display.swift', 'Framework.swift', 'Accounting.swift', 'MessageReader.swift', 'ProbeCap.swift',
                   'iOSClient/SessionLink.swift', 'iOSClient/KeyChords.swift', 'Sources/SillHost/KeyStrokes.swift', 'Sources/SillHost/SourceInputFence.swift',
                   'visionOSClient/VisionPointer.swift', 'visionOSClient/VisionInputSession.swift', 'visionOSClient/VisionInputDebt.swift',
                   'visionOSClient/VisionPresentation.swift', 'visionOSClient/VisionTextDraft.swift', 'visionOSClient/VisionRemoteKey.swift', 'main.swift']
    for name, source in files.items():
        path = out / 'generated' / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source)
    base = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(out / 'cache')]
    commands = []
    for name in ['Network', 'SwiftUI']:
        commands.append(base + ['-parse-as-library', '-emit-module', '-emit-object', '-module-name', name,
            str(out / 'generated' / (name + '.swift')), '-emit-module-path', str(out / (name + '.swiftmodule')), '-o', str(out / (name + '.o'))])
    app = base + ['-package-name', 'sill', '-I', str(out), '-I', str(modules)] + [str(out / 'generated' / s) for s in sources]
    app += [str(out / (n + '.o')) for n in ['Network', 'SwiftUI']] + [str(modules / 'StreamProtocol.o'), '-o', str(out / 'check')]
    commands += [app, [str(out / 'check')]]
    record = {'suite': suite, 'extractionSHA256': manifest, 'commands': [],
              'scope': '실제 소스 추출과 메모리 framework/Network 어댑터. 실제 UIKit·디코더·Host 설치·기기 수용 아님.',
              'inputSHA256': {name: hashlib.sha256(source.encode()).hexdigest() for name, source in files.items()}}
    if suite != 'vision':
        record['selection'] = '기존 presentation-epoch의 codec·reader·표시 layer·client permit·미디어 수신 검사. Host 송신·geometry 검사는 부모의 exact Host212 검사와 구분.'
    for index, command in enumerate(commands):
        run = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
        (out / f'{index}.log').write_text(run.stdout)
        record['commands'].append({'phase': index, 'exitCode': run.returncode})
        print(run.stdout, end='', flush=True)
        if run.returncode: break
    record['exitCode'] = record['commands'][-1]['exitCode']
    (out / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    return int(record['exitCode'] != 0)


if __name__ == '__main__':
    sys.exit(main())
