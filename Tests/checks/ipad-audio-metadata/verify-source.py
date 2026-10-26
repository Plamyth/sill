"""오디오 정책·권한·wire 원본과 진단 콜백 경계를 검증한다."""
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[3]
base = '14e941099ca5d27bb4c1df171849d601a14a1455'
unchanged = ['IPadAudioSession.swift','IPadAudioAdmission.swift','IPadAudioLeaseState.swift',
 'IPadAudioLeaseCoordinator.swift','IPadDesiredAudio.swift','IPadAudioForwarding.swift',
 'IPadRemoteAudioController.swift','IPadMicrophonePolicy.swift','IPadMicrophonePCM.swift']
for name in unchanged:
 path = 'iOSClient/'+name
 assert (root/path).read_bytes() == subprocess.check_output(['git','show',base+':'+path],cwd=root), path
player = (root/'iOSClient/RemoteAudioPlayer.swift').read_text()
render = player.split('let source = AVAudioSourceNode(format: format)')[1].split('engine.attach(source)')[0]
for forbidden in ['.record(', '.snapshot(', 'DispatchQueue', '.write(', 'NSLog', 'JSON']:
 assert forbidden not in render, forbidden
patch = subprocess.check_output(['git','diff',base,'--','iOSClient'],cwd=root,text=True)
added = '\n'.join(line for line in patch.splitlines() if line.startswith('+') and not line.startswith('+++'))
for effect in ['requestAccess(', 'setActive(', 'setCategory(', 'setDesiredAudioSelection(', 'takeAutomaticStarts(', 'AudioForwardingControl(']:
 assert effect not in added, effect
print('9 policy/lease/permission/PCM source files unchanged; callback I/O/main-sync and added media effects absent')
