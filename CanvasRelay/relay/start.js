'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

const tokenFile = path.join(os.homedir(),'Library','Application Support','CanvasBridgeRelay','token');
process.env.CANVAS_RELAY_TOKEN = fs.readFileSync(tokenFile,'utf8').trim();
const {createServer} = require('./server');
const server = createServer();
server.listen(8791,'192.168.45.4',() => process.stdout.write('CanvasBridge relay ready on 8791\n'));
