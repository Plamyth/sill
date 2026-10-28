'use strict';
const net = require('node:net'),child = require('node:child_process'),path = require('node:path'),fs = require('node:fs'),crypto = require('node:crypto');
const deny = name => function () { throw new Error('검사 격리 위반: '+name); };
net.Server.prototype.listen = deny('listen');net.Socket.prototype.connect = deny('connect');
require('node:dgram').createSocket = deny('datagram');globalThis.fetch = deny('fetch');
const spawn = child.spawnSync,root = process.env.CCR_FIX_MODULE_ROOT,tmp = fs.realpathSync(process.env.TMPDIR);
const inside = file => typeof file === 'string' && path.resolve(file).startsWith(tmp+path.sep);
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
for (const name of ['spawn','spawnSync','exec','execSync','execFile','fork']) child[name] = deny(name);
child.execFileSync = function(program,args,options) {
  const native = args?.[0] === path.join(root,'vault-note-exchange.py') && args.length === 3 &&
    inside(args[1]) && inside(args[2]) && program === (process.platform === 'darwin' ? '/usr/bin/python3' : 'python3');
  const writer = program === process.execPath && args?.[0] === path.join(root,'test-input/vault-external-writer.cjs') &&
    args.length === 4 && inside(args[1]);
  if (!native && !writer) throw new Error('허용되지 않은 자식 프로세스');
  const result = spawn(program,args,{...options,encoding:null});
  let pidGone = false;
  if (result.pid) { try { process.kill(result.pid,0); } catch (error) { pidGone = error.code === 'ESRCH'; } }
  fs.appendFileSync(process.env.CCR_CHILD_RECEIPTS,JSON.stringify({kind:native ? 'atomic-exchange' : 'fixture-writer',
    executable:program,helperSHA256:sha(fs.readFileSync(args[0])),argvSHA256:sha(JSON.stringify(args)),
    pid:result.pid,exitCode:result.status,signal:result.signal,pidGone})+'\n');
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error('허용된 검사 자식 프로세스 실패: '+result.status);
  return result.stdout;
};
