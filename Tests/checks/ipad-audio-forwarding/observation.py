"""Run existing model and the real metadata encoder without engines or credentials."""
from pathlib import Path
import json, os, re, subprocess, tempfile
root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
developer = '/Applications/Xcode.app/Contents/Developer' if Path('/Applications/Xcode.app').exists() else '/Library/Developer/CommandLineTools'
env = dict(os.environ, DEVELOPER_DIR=developer)
with tempfile.TemporaryDirectory(prefix='ipad-forwarding-observation-') as scratch:
    out = Path(scratch)
    subprocess.run(['sh', str(here/'run.sh'), str(out/'model')], check=True, cwd=root, env=env)
    source = (root/'iOSClient/IPadMicrophoneCapture.swift').read_text()
    # The actual diagnostics class ends before AVAudioFormat/engine-specific helpers.
    diagnostics = source[:source.index('    static func format(')].replace('import AVFoundation\n', '') + '}\n'
    (out/'Diagnostics.swift').write_text(diagnostics)
    forwarding = (root/'iOSClient/StreamClient+AudioForwarding.swift').read_text()
    guards = forwarding.split('var forwardingContextReadiness:', 1)[1].split('func reconcileAudioForwarding()', 1)[0]
    keys = re.findall(r'"([^"]+)":', guards)
    assert len(keys) == len(set(keys)) == 24
    (out/'guards.json').write_text(json.dumps({key: index % 2 == 0 for index, key in enumerate(keys)}))
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',
        '-I',str(out/'model'),'-L',str(out/'model'),'-lStreamProtocol',
        '-Xlinker','-rpath','-Xlinker',str(out/'model'),
        '-module-cache-path',str(out/'cache'),str(out/'Diagnostics.swift'),
        str(here/'observation-metadata.swift'),'-o',str(out/'metadata-check')],check=True,env=env)
    subprocess.run([str(out/'metadata-check'),str(out)],check=True)
print('scratchRemoved=' + str(not out.exists()).lower())
