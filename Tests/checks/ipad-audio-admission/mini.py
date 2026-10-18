"""Stream only this fixture's inputs into an owned Mini RAM volume, then reap it."""
from pathlib import Path
import base64, hashlib, json, subprocess, sys
root = Path(__file__).resolve().parents[3]
out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
if (out/'result.json').exists(): raise SystemExit('existing receipt must be reconciled')
paths = sorted((root/'Sources/StreamProtocol').glob('*.swift'))
paths += [root/'iOSClient'/n for n in ['IPadToolbarVisibility.swift','IPadAudioAdmission.swift','IPadMicrophonePCM.swift','IPadMicrophoneFrameGate.swift','IPadMicrophoneCapture.swift','IPadRemoteAudioController.swift','IPadDesiredAudio.swift','IPadMicrophonePolicy.swift','IPadAudioRoutePolicy.swift','StreamClient.swift','StreamClient+DesiredAudio.swift','StreamClient+Audio.swift','StreamClient+Microphone.swift','StreamClient+AudioRoutes.swift','RemoteAudioPlayer.swift','StreamScreen.swift','HostSettingsPanel.swift']]
paths += [root/'Tests/checks'/n for n in ['swift_platform.py','ipad-microphone-frame-gate/main.swift','iPad-remote-audio/main.swift','iPad-remote-audio/fixture.py','iPad-remote-audio/player-fixture.py','iPad-remote-audio/player-standins.swift','ipad-audio-admission/run.py','ipad-audio-admission/main.swift','ipad-desired-audio/permission-lifecycle.py','ipad-desired-audio/intent-adapters.py','ipad-desired-audio/main.swift','ipad-audio-admission/nearby.py']]
sha=lambda b:hashlib.sha256(b).hexdigest()
source={str(p.relative_to(root)):p.read_bytes() for p in paths}
hashes={n:sha(b) for n,b in source.items()}
payload=json.dumps({'hashes':hashes,'source':{n:base64.b64encode(b).decode() for n,b in source.items()}}).encode()
runner=(root/'Tests/checks/ipad-full-duplex/remote.py').read_text()
a=runner.index("    flags =")
b=runner.index("    record['memorySourcesUnchanged']",a)
runner=runner[:a]+'''    check('admission', ['python3', '-B', str(mount / 'Tests/checks/ipad-audio-admission/run.py'), str(output)], 180)
    check('nearby', ['python3', '-B', str(mount / 'Tests/checks/ipad-audio-admission/nearby.py'), str(output)], 180)
'''+runner[b:]
# Generated fixture sources and compiler caches also stay in RAM.
runner=runner.replace("output = Path(tempfile.mkdtemp(prefix='ccr-mic-converter-', dir='/private/tmp'))", "output = mount / 'output'; output.mkdir()")
runner=runner.replace("'ram://262144'", "'ram://1048576'").replace('135 * 1024 * 1024','537 * 1024 * 1024')
runner=runner.replace("record['before'] = health()", "record['before'] = health()\nrecord['existingRAM'] = subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist']).decode(errors='replace')")
child=subprocess.Popen(['/Users/ambrion/.local/bin/mini','heavy','--cwd','/private/tmp','--','python3','-B','-c',runner],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
log,_=child.communicate(payload,timeout=460)
(out/'run.log').write_bytes(log)
lines=log.decode(errors='replace').splitlines()
records=[s.removeprefix('RESULT_JSON ') for s in lines if s.startswith('RESULT_JSON ')]
result={'exitCode':child.returncode,'inputSHA256':sha(payload),'senderReceiverMatch':('INPUT_SHA256 '+sha(payload)) in lines,'sourceSHA256':hashes,'sourceUnchanged':all(sha((root/n).read_bytes())==h for n,h in hashes.items()),'transportReaped':child.poll() is not None,'remote':json.loads(records[-1]) if records else None,'scope':'narrow native SDK fixture in Mini RAM, not source-guard migration or live media acceptance'}
(out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
if result['remote']:
 for check in result['remote'].get('checks',[]): print(check['name'],check['exitCode'],check['log'][-6000:])
 print(result['remote'].get('error',''))
else: print(log.decode(errors='replace')[-6000:])
print(json.dumps({k:result[k] for k in ['exitCode','sourceUnchanged','senderReceiverMatch','transportReaped']}))
sys.exit(child.returncode)
