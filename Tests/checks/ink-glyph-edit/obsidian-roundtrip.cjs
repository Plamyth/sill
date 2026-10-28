'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const output = fs.realpathSync(process.argv[2]);
const flow = process.argv[3] === 'shape' ? 'shape' : 'glyph';
const relay = fs.realpathSync('/Users/ambrion/Documents/ChatGPT/BT_CCR-Obsidian-relay');
const inputs = ['relay/obsidian-vault.js', 'relay/canvas-diagram.js'];
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const hashes = () => Object.fromEntries(inputs.map(p => [p, sha(fs.readFileSync(path.join(relay, p)))]));
const before = hashes();
const {ObsidianVault} = require(path.join(relay, 'relay/obsidian-vault.js'));
const root = path.join(output, 'isolated-obsidian-' + crypto.randomUUID());
fs.mkdirSync(root, {mode: 0o700});
fs.writeFileSync(path.join(root, '.glyph-fixture-owner'), 'ink-glyph-edit');
const vault = new ObsidianVault(root);
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=', 'base64');
let checks = 0;
function ok(value, label) { assert(value, label); checks++; }
const originalBytes = fs.readFileSync(path.join(output, flow + '-before.json'));
const afterBytes = fs.readFileSync(path.join(output, flow + '-after.json'));
const undoBytes = fs.readFileSync(path.join(output, flow + '-undo.json'));
const original = JSON.parse(originalBytes), after = JSON.parse(afterBytes), undo = JSON.parse(undoBytes);
let saved = vault.saveCanvas(original.id, original.revision, originalBytes, png, null);
let read = new ObsidianVault(root).canvas(original.id);
ok(Buffer.from(read.sceneJSONBase64, 'base64').equals(originalBytes), 'original JSON actual files');
const memo = '\r\n사용자 메모 e\u0301 👩‍💻\r\n';
const note = vault.note(saved.path);
const withMemo = vault.save(saved.path, note.sha256, note.text + memo);
saved = vault.saveCanvas(after.id, after.revision, afterBytes, png, withMemo.sha256);
read = new ObsidianVault(root).canvas(after.id);
const loaded = JSON.parse(Buffer.from(read.sceneJSONBase64, 'base64'));
ok(read.sceneSha256 === sha(afterBytes), 'saved SHA');
ok(Buffer.from(read.sceneJSONBase64, 'base64').equals(afterBytes), 'edited JSON byte equality');
ok(loaded.drawingBase64 === after.drawingBase64, 'native saved bytes');
if (flow === 'glyph') {
  ok(loaded.nodes[0].text === '가다', 'edited text and ink saved together');
} else {
  const node = loaded.nodes.find(n => !original.nodes.some(old => old.id === n.id));
  ok(node && node.kind === 'box' && node.confidence === 'confirmed', 'new confirmed box survives actual vault file');
  ok(JSON.stringify(node.sourceStrokeIds) === JSON.stringify(after.nodes.find(n => n.id === node.id).sourceStrokeIds), 'shape source IDs preserved');
  ok(loaded.drawingBase64 === original.drawingBase64 && JSON.stringify(loaded.strokes) === JSON.stringify(original.strokes), 'shape original ink remains exact');
}
ok(JSON.stringify(loaded.strokes) === JSON.stringify(after.strokes), 'pressure masks and transform projection');
ok(vault.note(saved.path).text.includes(after.nodes[0].text), 'human readable Markdown projection');
ok(vault.note(saved.path).text.endsWith(memo), 'memo exact UTF8 CRLF preserved');
const currentBytes = fs.readFileSync(path.join(root, saved.path));
assert.throws(() => vault.saveCanvas(original.id, original.revision, originalBytes, png, withMemo.sha256), e => e.status === 409);
checks++;
ok(fs.readFileSync(path.join(root, saved.path)).equals(currentBytes), 'stale CAS preserves current Markdown');
const reverted = vault.saveCanvas(undo.id, undo.revision, undoBytes, png, saved.noteSha256);
read = new ObsidianVault(root).canvas(undo.id);
ok(Buffer.from(read.sceneJSONBase64, 'base64').equals(undoBytes), 'undo new process readback');
ok(JSON.parse(Buffer.from(read.sceneJSONBase64, 'base64')).drawingBase64 === original.drawingBase64, 'undo native original exact bytes');
ok(vault.note(reverted.path).text.endsWith(memo), 'undo memo unchanged');
const now = vault.note(reverted.path);
const external = vault.save(now.path, now.sha256, now.text + '외부 메모\n');
assert.throws(() => vault.saveCanvas(after.id, after.revision, afterBytes, png, reverted.noteSha256), e => e.status === 409);
checks++;
ok(vault.note(now.path).sha256 === external.sha256, 'external edit not overwritten');
assert.deepEqual(hashes(), before);
const result = {schema: 'ccr.ink-obsidian-files/v1', flow, checks, failed: 0, root, sourceHashes: before,
  sourceUnchanged: true, actualVaultModule: true, sharedRuntimeChanged: false, network: false,
  imageScope: 'one-pixel fixture; native bytes/JSON/Markdown/CAS; shape Mermaid remains generic; preview rendering separately SDK/build',
  evidenceMappingInjected: flow === 'glyph', nativeRecognitionSuccessProven: false};
fs.writeFileSync(path.join(output, 'obsidian-' + flow + '-roundtrip.json'), JSON.stringify(result, null, 2) + '\n');
console.log(JSON.stringify(result));
