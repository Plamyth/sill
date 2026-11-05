"""기존 player fixture와 실제 metadata encoder. 실제 엔진·장치·세션은 가짜다."""
from pathlib import Path
import subprocess,tempfile

root=Path(__file__).resolve().parents[3]
here=Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='render-levels-') as folder:
    out=Path(folder).resolve()
    source=(root/'iOSClient/IPadMicrophoneCapture.swift').read_text().split('final class IPadMicrophoneConversionWorker')[0]
    source=source.replace('FileManager.default.urls(for: .applicationSupportDirectory,\n        in: .userDomainMask)[0].appendingPathComponent("CCR Sill/microphone-diagnostics.json")',
                          'URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("events.json")')
    (out/'Diagnostics.swift').write_text(source)
    subprocess.run(['python3','-B',str(here/'player-fixture.py'),str(root),str(out)],check=True)
    flags=['xcrun','swiftc','-swift-version','5','-module-cache-path',str(out/'cache')]
    subprocess.run(flags+['-emit-library','-emit-module','-module-name','StreamProtocol',*[str(p) for p in (root/'Sources/StreamProtocol').glob('*.swift')],
                          '-o',str(out/'libStreamProtocol.dylib'),'-emit-module-path',str(out/'StreamProtocol.swiftmodule')],check=True)
    shared=['-parse-as-library','-I',str(out),'-L',str(out),'-lStreamProtocol','-Xlinker','-rpath','-Xlinker',str(out)]
    subprocess.run(flags+shared+[str(out/'Diagnostics.swift'),str(root/'iOSClient/IPadAudioAdmission.swift'),str(root/'iOSClient/IPadRemoteAudioController.swift'),str(out/'PlaybackFixture.swift'),
                                str(here/'render-levels.swift'),'-o',str(out/'render-check')],check=True)
    subprocess.run([str(out/'render-check'),str(out)],check=True)
    subprocess.run(flags+['-parse-as-library',str(out/'Diagnostics.swift'),str(root/'Tests/checks/ipad-audio-metadata/main.swift'),'-o',str(out/'metadata-check')],check=True)
    subprocess.run([str(out/'metadata-check'),str(out/'metadata')],check=True)
    callback=(root/'iOSClient/RemoteAudioPlayer.swift').read_text().split('let source = AVAudioSourceNode',1)[1].split('engine.attach(source)',1)[0]
    baseline_callback=callback.replace('''                                if observes && ready && channel < channels {
                                    self.renderCounters?.recordCopiedSample(destination[frame])
                                }
''','')
    assert callback.count('withLock') == baseline_callback.count('withLock') == 2
    assert not any(x in callback for x in ['record("','count(','Data(','Array(','Task','async','sqrt','squareRoot','write('])
    print('PASS callback has no new locks, allocation/I-O calls, dispatch or RMS calculation')
print('scratchRemoved='+str(not out.exists()).lower())
