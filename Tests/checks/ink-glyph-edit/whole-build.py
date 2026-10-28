#!/usr/bin/env python3
"""정확한 clean HEAD의 정상 Sill 번들을 서명·설치·네트워크 없이 빌드한다."""
from pathlib import Path
import os, json, subprocess, uuid, hashlib, plistlib, datetime, argparse
root=Path(__file__).resolve().parents[3]
here=Path(__file__).resolve().parent
def git(*args): return subprocess.check_output(['git','-C',str(root),*args],text=True).strip()
assert not git('status','--porcelain=v1','--untracked-files=all'), 'clean source required'
route=json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))
parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
assert any(p.exists() and os.path.samefile(p,route['path']) for p in [args.output,*args.output.parents])
head,tree=git('rev-parse','HEAD'),git('rev-parse','HEAD^{tree}')
out=args.output/('whole-'+str(uuid.uuid4()));out.mkdir(parents=True)
profile=Path(route['path'])/'owner-mac-bootstrap-20261022/public-profile-from-ipad-saved.json'
profile_sha=hashlib.sha256(profile.read_bytes()).hexdigest()
assert profile_sha=='7bcf8ce74bf4292d1a20b07d45bfa0c040957e1ade3d80dd4be37c5eb96cf8c7'
home=out/'home';home.mkdir();tmp=out/'tmp';tmp.mkdir()
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(home),CFFIXED_USER_HOME=str(home),TMPDIR=str(tmp)+'/')
cmd=['xcodebuild','-project','iOSClient/Sill.xcodeproj','-scheme','Sill','-configuration','Debug','-destination','generic/platform=iOS',
 '-derivedDataPath',str(out/'DerivedData'),'-disableAutomaticPackageResolution','-skipPackageUpdates',
 'CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO','DEVELOPMENT_TEAM=ZPTXHJ866D',
 'PRODUCT_BUNDLE_IDENTIFIER=com.ambrion.sillcanvas.ipad','ARCHS=arm64',
 'CCR_OWNER_MAC_BOOTSTRAP_PROFILE='+str(profile),'CCR_OWNER_MAC_BOOTSTRAP_SHA256='+profile_sha,
 'CCR_SOURCE_GIT_COMMON_DIR='+str(Path(git('rev-parse','--git-common-dir')).resolve()),
 'CLANG_MODULE_CACHE_PATH='+str(out/'modules'),'SWIFT_MODULE_CACHE_PATH='+str(out/'modules'),'build']
record=dict(schema='ccr.ink-product-whole-build/v1',commit=head,tree=tree,output=str(out),command=cmd,
 startedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),installation=False,push=False,deviceHostEffects=0,shapeContractAccepted=False)
(out/'build.json').write_text(json.dumps(record,indent=2)+'\n')
print('BUILD_OUTPUT',out,flush=True)
with (out/'xcodebuild.log').open('w') as log:
 r=subprocess.run(cmd,cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT)
record['exitCode']=r.returncode
record['sourceUnchanged']=not git('status','--porcelain=v1','--untracked-files=all') and git('rev-parse','HEAD')==head and git('rev-parse','HEAD^{tree}')==tree
app=out/'DerivedData/Build/Products/Debug-iphoneos/Sill.app'
if r.returncode==0:
 info=plistlib.loads((app/'Info.plist').read_bytes())
 record['app']=str(app);record['info']={k:info.get(k) for k in ['CFBundleIdentifier','CFBundleVersion','CCRSourceCommit','CCRSourceTree','CCRSourceIdentityVerified']}
 record['identityMatches']=info.get('CCRSourceCommit')==head and info.get('CCRSourceTree')==tree and info.get('CCRSourceIdentityVerified') is True
 record['executableSHA256']=hashlib.sha256((app/info['CFBundleExecutable']).read_bytes()).hexdigest()
 record['signatureDirectoryExists']=(app/'_CodeSignature').exists()
record['passed']=r.returncode==0 and record['sourceUnchanged'] and record.get('identityMatches',False)
record['finishedAt']=datetime.datetime.now(datetime.timezone.utc).isoformat()
(out/'build.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(record,ensure_ascii=False),flush=True)
raise SystemExit(0 if record['passed'] else 1)
