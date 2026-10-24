'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { createHash } = require('node:crypto');

const adapterPath = '/Users/ambrion/.codex/worktrees/ccr-device-enrollment-core-20261025/plugin/enrollment-host-adapter.js';
const adapterBytes = fs.readFileSync(adapterPath);
const { createEnrollmentHostAdapter } = require(adapterPath);
const output = process.argv[2];
const read = name => JSON.parse(fs.readFileSync(path.join(output, name), 'utf8'));
const attach = read('attach.json'), identity = read('identity.json'), active = read('active.json');
const hc = read('host-challenge.json'), challenge = read('challenge.json');
const payload = JSON.parse(Buffer.from(active.envelope.payload, 'base64url'));
const pinParent = fs.mkdtempSync(path.join(output, 'inert-node-pin-'));
fs.chmodSync(pinParent, 0o700);
const anchor = Object.freeze({ inert: true });
const writes = [];
class MemorySocket extends EventEmitter {
  constructor() {
    super(); this.destroyed = false; this.readable = true; this.writable = true;
    this.readableEnded = false; this.writableEnded = false;
  }
  write(raw, callback) {
    const message = JSON.parse(raw); writes.push(message);
    if (message.op === 'enrollment.host.challenge') {
      assert.deepEqual(message, hc);
      queueMicrotask(() => this.emit('data', Buffer.from(JSON.stringify(identity) + '\n')));
    } else {
      assert.deepEqual(message, challenge);
      const bytes = Buffer.from(JSON.stringify(active) + '\n');
      queueMicrotask(() => { this.emit('data', bytes.subarray(0, 17)); this.emit('data', bytes.subarray(17)); });
    }
    callback?.(); return true;
  }
  destroy() { this.destroyed = true; this.readable = false; this.writable = false; }
}
(async () => {
  const socket = new MemorySocket();
  const adapter = createEnrollmentHostAdapter({ origin: hc.origin, pinFile: path.join(pinParent, 'pin.json'),
    now: () => payload.checkedAt,
    randomUUID: () => hc.coreGeneration,
    randomBytes: size => size === 32 ? Buffer.from(hc.nonce, 'base64url') : Buffer.alloc(size, 1),
    peerVerifier: { prepare: async () => {}, verify: async () => anchor,
      current: (value, transport) => value === anchor && transport === socket && !socket.destroyed }
  });
  const profile = await adapter.attach(socket, attach);
  assert.equal(profile.publicSPKI, identity.envelope.publicSPKI);
  const request = Object.fromEntries(['requestId', 'nonce', 'deviceFingerprint', 'ownerPrincipal', 'origin', 'deadline']
    .map(key => [key, challenge[key]]));
  const result = await adapter.checkDevice(request);
  assert.equal(result.body.active, true);
  assert.equal(result.body.requestDigest, challenge.requestDigest);
  assert.deepEqual(result.envelope, active.envelope);
  adapter.close(); assert.equal(socket.destroyed, true);
  assert.deepEqual(fs.readFileSync(adapterPath), adapterBytes);
  fs.writeFileSync(path.join(output, 'node-compat.json'), JSON.stringify({
    passed: true, adapterPath,
    adapterSHA256: createHash('sha256').update(adapterBytes).digest('hex'), adapterSourceUnchanged: true,
    actualCommandSocketConnections: 0, actualOSSocketConnections: 0,
    peerVerifier: 'inert anchor; no installed app identity verification',
    pinFile: path.join(pinParent, 'pin.json'), writes: writes.length,
    signatureValidation: 'real production Node adapter and Swift signer'
  }, null, 2));
  console.log('production Node adapter accepted Swift attach/identity/active signature; OS sockets=0');
})().catch(error => { console.error(error); process.exitCode = 1; });
