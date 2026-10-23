"""설치·서명·로그인 없이 실제 iOS SDK로 앱을 빌드한다. 공개 합성 bootstrap만 사용한다."""
from pathlib import Path
import base64
import hashlib
import json
import os
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
profile = out / 'synthetic-bootstrap.json'
data = json.dumps({'schema': 'ccr.owner-mac-bootstrap/v1', 'macID': '0' * 16,
    'fingerprint': base64.urlsafe_b64encode(bytes(32)).decode().rstrip('='),
    'addresses': ['100.64.1.2'], 'remotePort': 7455}).encode()
profile.write_bytes(data)
profile.chmod(0o600)
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
args = ['xcodebuild', '-project', str(root/'iOSClient/Sill.xcodeproj'), '-scheme', 'Sill',
    '-configuration', 'Debug', '-sdk', 'iphoneos', '-destination', 'generic/platform=iOS',
    '-derivedDataPath', str(out/'DerivedData'), 'CODE_SIGNING_ALLOWED=NO', 'COMPILER_INDEX_STORE_ENABLE=NO',
    'CCR_OWNER_MAC_BOOTSTRAP_PROFILE=' + str(profile),
    'CCR_OWNER_MAC_BOOTSTRAP_SHA256=' + hashlib.sha256(data).hexdigest(),
    '-disableAutomaticPackageResolution', 'build']
with (out/'ios-build.log').open('w') as log:
    result = subprocess.run(args, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
print('iOS SDK build exit:', result.returncode)
raise SystemExit(result.returncode)
