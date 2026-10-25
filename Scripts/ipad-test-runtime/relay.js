'use strict';
const fs = require('node:fs');
const path = require('node:path');
const [configPath] = process.argv.slice(2);
const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
const {createServer} = require(path.join(config.relayRepo, 'relay/server.js'));
const server = createServer({
  token: config.token, vaultRoot: config.vault, store: config.store,
  snapshotPath: config.snapshot, hiddenPath: config.hidden,
  deliveryReady: async () => false,
  deliver: async () => { throw new Error('격리 테스트에서는 외부 대화로 전송하지 않습니다.'); }
});
// Test-only wire evidence: observe the existing note endpoint without changing its response.
if (config.noteAudit) server.prependListener('request', (request, response) => {
  const url = new URL(request.url, 'http://localhost');
  if (request.method !== 'PUT' || url.pathname !== '/vault/note') return;
  const chunks = [];
  let size = 0;
  request.on('data', bytes => {
    size += bytes.length;
    if (size <= 1024 * 1024 + 4096) chunks.push(bytes);
  });
  response.on('finish', () => {
    let body;
    try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { body = {}; }
    const sha = value => typeof value === 'string'
      ? require('node:crypto').createHash('sha256').update(value).digest('hex') : null;
    fs.appendFileSync(config.noteAudit, JSON.stringify({path:url.searchParams.get('path'),
      status:response.statusCode, baseSha256:body.baseSha256 ?? null, textSha256:sha(body.text)}) + '\n', {mode:0o600});
  });
});
server.listen(config.port, config.host);
