'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = process.env.PENCIL_TEST_VAULT;
const fixture = process.env.PENCIL_FIXTURE_ID;
assert(path.isAbsolute(root) && /^[0-9a-f-]{36}$/.test(fixture));
const marker = path.join(root, '.pencil-fixture-owner');
if (!fs.existsSync(root)) {
  fs.mkdirSync(root, {mode: 0o700});
  fs.writeFileSync(marker, fixture, {flag: 'wx', mode: 0o600});
}
assert(!fs.lstatSync(root).isSymbolicLink());
assert.equal(fs.readFileSync(marker, 'utf8'), fixture);
const {ObsidianVault} = require(path.join(process.env.PENCIL_RELAY_REPO, 'relay/obsidian-vault.js'));
const vault = new ObsidianVault(root);
const request = JSON.parse(fs.readFileSync(0, 'utf8'));
let value;
try {
  switch (request.operation) {
    case 'readNote': value = vault.note(request.path); break;
    case 'saveNote': value = vault.save(request.path, request.baseSha256, request.text); break;
    case 'readCanvas': value = vault.canvas(request.id); break;
    case 'saveCanvas': value = vault.saveCanvas(request.id, request.revision,
      Buffer.from(request.scene, 'base64'), Buffer.from(request.png, 'base64'), request.baseSha256); break;
    default: throw new Error('Unsupported fixture operation');
  }
  process.stdout.write(JSON.stringify({ok: true, value}));
} catch (error) {
  process.stdout.write(JSON.stringify({ok: false, status: error.status || 500, message: error.message}));
}
