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
server.listen(config.port, config.host);
