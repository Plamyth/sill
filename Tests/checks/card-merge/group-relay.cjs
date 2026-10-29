// Own offline data through the existing vault implementation. No listener or live vault.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { ObsidianVault } = require('../../../CanvasRelay/relay/obsidian-vault.js');
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const bytes = Buffer.from(input.sceneBase64, 'base64');
const png = Buffer.from(input.pngBase64, 'base64');
const scene = JSON.parse(bytes);
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ccr-group-own-'));
const hash = b => crypto.createHash('sha256').update(b).digest('hex');
let result;
try {
  const vault = new ObsidianVault(root);
  const saved = vault.saveCanvas(scene.id, scene.revision, bytes, png, null);
  const fresh = new ObsidianVault(root);
  const read = fresh.canvas(scene.id);
  assert.deepEqual(Buffer.from(read.sceneJSONBase64, 'base64'), bytes);
  const marks = scene.annotations.filter(a => a.author === 'ccr.sill.group/v1');
  assert.equal(marks.length, 1);
  const groupID = marks[0].nodeId;
  const links = scene.links.filter(l => l.from === groupID && l.label.startsWith('ccr.sill.group/v1 · '));
  assert.equal(links.length, 2);
  const ordered = links.slice().sort((a,b) => Number(a.label.split(' · ')[1]) - Number(b.label.split(' · ')[1]));
  assert.ok(ordered.every(l => l.kind === 'general' && scene.nodes.some(n => n.id === l.to && n.vaultNote?.blockID)));
  const note = fresh.note(saved.path);
  assert.ok(note.text.includes(groupID));
  for (const link of ordered) assert.ok(note.text.includes(link.to));
  const external = structuredClone(scene);
  external.revision++;
  external.nodes.find(n => n.id === groupID).text = '외부 그룹 제목 e\u0301';
  for (const link of external.links.filter(l => l.from === groupID && l.label.startsWith('ccr.sill.group/v1 · '))) {
    const index = Number(link.label.split(' · ')[1]); link.label = `ccr.sill.group/v1 · ${3 - index}`;
  }
  external.annotations.find(a => a.author !== 'ccr.sill.group/v1').text = '외부 댓글\r\ne\u0301';
  const externalBytes = Buffer.from(JSON.stringify(external));
  const changed = fresh.saveCanvas(scene.id, external.revision, externalBytes, png, read.noteSha256);
  assert.throws(() => vault.saveCanvas(scene.id, scene.revision, bytes, png, saved.noteSha256), { status:409 });
  const reopened = new ObsidianVault(root).canvas(scene.id);
  assert.deepEqual(Buffer.from(reopened.sceneJSONBase64, 'base64'), externalBytes);
  assert.equal(reopened.noteSha256, changed.noteSha256);
  assert.deepEqual(external.nodes.filter(n => n.id !== groupID), scene.nodes.filter(n => n.id !== groupID));
  assert.equal(external.drawingBase64, scene.drawingBase64);
  assert.deepEqual(external.strokes, scene.strokes);
  const assets = path.join(root, 'CCR Canvas', 'Assets');
  const all = fs.readdirSync(assets).map(name => fs.readFileSync(path.join(assets,name)));
  assert.ok(all.some(b => b.equals(bytes)) && all.some(b => b.equals(externalBytes)) && all.some(b => b.equals(png)));
  result = { passed:true, exactOriginalSceneReopened:true, sameOrderedIDs:true,
    reverseJSONTitleCommentAndOrder:true, originalCardsInkAndAssetsPreserved:true, staleCASRefused:true,
    sceneSHA256:hash(bytes), externalSHA256:hash(externalBytes), externalSceneBase64:externalBytes.toString('base64'),
    HTTP:false, listener:false, liveVault:false, root };
} finally { fs.rmSync(root, { recursive:true, force:true }); }
result.fixtureRemoved = !fs.existsSync(root);
assert.equal(result.fixtureRemoved,true);
console.log(JSON.stringify(result));
