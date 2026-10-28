// The existing vault implementation, on an owned offline fixture only. No server is started.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { ObsidianVault } = require('../../../CanvasRelay/relay/obsidian-vault.js');
const output = path.resolve(process.argv[2]);
const root = path.join(output, 'own-offline-vault');
fs.mkdirSync(root, { recursive: false });
const sceneBytes = fs.readFileSync(path.join(output, 'merged-scene.json'));
const scene = JSON.parse(sceneBytes);
const image = fs.readFileSync(path.join(output, 'preview.png'));
const vault = new ObsidianVault(root);
const saved = vault.saveCanvas(scene.id, scene.revision, sceneBytes, image, null);
const fresh = new ObsidianVault(root);
const read = fresh.canvas(scene.id);
assert.deepEqual(Buffer.from(read.sceneJSONBase64, 'base64'), sceneBytes);
const decoded = JSON.parse(Buffer.from(read.sceneJSONBase64, 'base64'));
assert.deepEqual(decoded.nodes, scene.nodes);
assert.deepEqual(decoded.links, scene.links);
assert.deepEqual(decoded.annotations, scene.annotations);
const aggregate = scene.nodes.at(-1);
const note = fresh.note(saved.path);
assert.ok(note.text.includes(aggregate.id));
assert.ok(note.text.includes('[1]\nBeta'));
const refs = scene.links.filter(x => x.from === aggregate.id && x.label.startsWith('병합 원본 · '));
assert.equal(refs.length, 2);
for (const link of refs) {
  const original = decoded.nodes.find(x => x.id === link.to);
  assert.ok(original.vaultNote.path.endsWith('.md') && original.vaultNote.blockID);
}
const external = structuredClone(scene);
external.revision++;
external.nodes[0].text = 'offline external writer';
const externalBytes = Buffer.from(JSON.stringify(external));
const externalSaved = fresh.saveCanvas(scene.id, external.revision, externalBytes, image, read.noteSha256);
assert.throws(() => vault.saveCanvas(scene.id, scene.revision, sceneBytes, image, saved.noteSha256), { status: 409 });
const final = new ObsidianVault(root).canvas(scene.id);
assert.deepEqual(Buffer.from(final.sceneJSONBase64, 'base64'), externalBytes);
assert.equal(final.noteSha256, externalSaved.noteSha256);
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
fs.writeFileSync(path.join(output, 'relay-result.json'), JSON.stringify({
  passed: true, actualVaultModule: true, sceneSHA256: hash(sceneBytes), externalSHA256: hash(externalBytes),
  exactSceneBytesReopened: true, sourceReferencesAndOrderPreserved: true, staleCASRefused: true,
  HTTP: false, service: false, liveVault: false, device: false
}, null, 2) + '\n');
console.log('CARD_MERGE_OFFLINE_RELAY_OK');
