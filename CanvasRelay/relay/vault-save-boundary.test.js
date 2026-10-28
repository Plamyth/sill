'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const child = require('node:child_process');
const {ObsidianVault} = require('./obsidian-vault');
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC','base64');
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(),'vault-save-boundary-'));
  const vault = new ObsidianVault(root),id = crypto.randomUUID();
  const scene = {schemaVersion:2,id,revision:1,width:200,height:100,drawingBase64:'',strokes:[],nodes:[],links:[],annotations:[]};
  const bytes = Buffer.from(JSON.stringify(scene));
  const first = vault.saveCanvas(id,1,bytes,png,null),note = vault.note(first.path);
  const next = {...scene,revision:2},proposed = Buffer.from(JSON.stringify(next));
  return {root,vault,id,first,note,scene,bytes,next,proposed,file:path.join(root,first.path)};
}
function preservedBytes(root) {
  const values = [];
  for (const entry of fs.readdirSync(root,{withFileTypes:true})) {
    const file = path.join(root,entry.name);
    if (entry.isDirectory()) values.push(...preservedBytes(file));
    else if (entry.isFile()) values.push(fs.readFileSync(file));
  }
  return values;
}
function atPublication(file,write,operation) {
  const rename = fs.renameSync,link = fs.linkSync,exec = child.execFileSync;
  let injected = false;
  const inject = () => { if (!injected) { injected = true;write(); } };
  fs.renameSync = function (from,to) { if (to === file) inject();return rename.apply(this,arguments); };
  fs.linkSync = function (from,to) { if (to === file) inject();return link.apply(this,arguments); };
  child.execFileSync = function (program,args) {
    if (args?.[0]?.endsWith('vault-note-exchange.py') && args[2] === file) inject();
    return exec.apply(this,arguments);
  };
  try { return operation(() => injected); }
  finally { fs.renameSync = rename;fs.linkSync = link;child.execFileSync = exec; }
}

for (const mode of ['in-place','atomic-replace']) {
  test(`마지막 SHA 확인 뒤 ${mode} 외부 메모는 보존되며 저장 성공으로 반환하지 않는다`, t => {
    const f = fixture(t),external = f.note.text+'\n외부에서 입력한 유일한 메모 '+mode+'\n';
    atPublication(f.file,() => {
      child.execFileSync(process.execPath,[path.join(__dirname,'test-input/vault-external-writer.cjs'),f.file,
        Buffer.from(external).toString('base64'),mode]);
      assert.equal(fs.readFileSync(f.file,'utf8'),external);
    },injected => {
      let error;
      try { f.vault.saveCanvas(f.id,2,f.proposed,png,f.first.noteSha256); } catch (caught) { error = caught; }
      assert.ok(injected(),'실제 파일 publication 경합 지점에 도달했다');
      assert.equal(error?.status,409,'실제 외부 쓰기를 성공으로 숨기지 않는다');
      const contents = preservedBytes(f.root);
      assert.ok(contents.some(bytes => bytes.equals(Buffer.from(external))),'외부 바이트 복구 가능');
      assert.ok(contents.some(bytes => bytes.equals(Buffer.from(f.note.text))),'원본 바이트 복구 가능');
      assert.ok(contents.some(bytes => bytes.includes(Buffer.from('ccr_scene_sha256: '+sha(f.proposed)))),'제안본 복구 가능');
    });
  });
}

test('동일 hash JSON symlink는 노트 전환 전에 거부하며 마지막 정상 세대를 재열 수 있다', t => {
  const f = fixture(t),backing = path.join(f.root,'backing.json');
  fs.writeFileSync(backing,f.proposed);
  const asset = path.join(f.root,'CCR Canvas/Assets',`${f.id}-${sha(f.proposed)}.json`);
  fs.symlinkSync(backing,asset);
  assert.throws(() => f.vault.saveCanvas(f.id,2,f.proposed,png,f.first.noteSha256),{status:409});
  assert.equal(f.vault.note(f.first.path).sha256,f.note.sha256);
  assert.equal(new ObsidianVault(f.root).canvas(f.id).sceneSha256,sha(f.bytes));
  assert.ok(fs.lstatSync(asset).isSymbolicLink());
  assert.deepEqual(fs.readFileSync(backing),f.proposed);
});

test('정상 저장 성공은 새 인스턴스 JSON·PNG 재열기와 일치한다', t => {
  const f = fixture(t),saved = f.vault.saveCanvas(f.id,2,f.proposed,png,f.first.noteSha256);
  const read = new ObsidianVault(f.root).canvas(f.id);
  assert.equal(read.noteSha256,saved.noteSha256);
  assert.equal(read.sceneSha256,saved.sceneSha256);
  assert.equal(read.imageSha256,saved.imageSha256);
  assert.deepEqual(Buffer.from(read.sceneJSONBase64,'base64'),f.proposed);
});
