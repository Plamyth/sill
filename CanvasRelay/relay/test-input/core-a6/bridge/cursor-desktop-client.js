'use strict';

const fs = require('node:fs/promises');
const { constants } = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { randomUUID } = require('node:crypto');

const UUID = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const THREAD = /^(?:bc-)?[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const HASH = /^[a-f0-9]{64}$/;
const EFFECT_ACTIONS = Object.freeze(['open-exact', 'focus', 'open-model', 'open-context', 'open-settings', 'open-review']);
const READ_ACTIONS = ['probe', 'read-selection'];
const ACTIONS = [...READ_ACTIONS, ...EFFECT_ACTIONS, 'open-mode', 'set-model', 'input', 'send', 'queue', 'approval', 'cancel', 'start-voice', 'terminal'];
const LIMITS = Object.freeze({ instances: 32, discoveryBytes: 16384, requestBytes: 16384,
  responseBytes: 65536, journalBytes: 262144, intents: 4096 });
const INSTANCE_KEYS = ['instanceId', 'pid', 'startedAt', 'workspaceUris', 'workspaceIdentity', 'app', 'vscodeVersion'];
const UNCERTAIN_CODES = new Set(['effect-sequence-conflict', 'effect-sequence-retired', 'effect-sequence-gap',
  'instance-mismatch', 'instance-uncertain', 'operation-busy', 'closed']);
const RESPONSE_CODES = {
  observed: ['selection-read'],
  unsupported: ['command-unregistered'],
  notExecuted: [...UNCERTAIN_CODES, 'operation-stopped', 'workspace-mismatch', 'invalid-native-selection',
    'selection-mismatch', 'native-command-failed', 'target-not-sole-selection'],
  commandCompleted: ['native-readback'],
  indeterminate: ['operation-timeout', 'operation-stopped', 'instance-mismatch', 'workspace-mismatch',
    'invalid-native-selection', 'selection-mismatch', 'native-command-failed']
};
const busyInstances = new Set();

class CursorDesktopClientError extends Error {
  constructor(code, receipt) {
    super(code);
    this.name = 'CursorDesktopClientError';
    this.code = code;
    if (receipt) this.receipt = receipt;
  }
}
const fail = code => { throw new CursorDesktopClientError(code); };
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const only = (value, keys) => record(value) && Object.keys(value).every(key => keys.includes(key));
const same = (left, right) => JSON.stringify(left) === JSON.stringify(right);
const sequence = value => Number.isSafeInteger(value) && value > 0;
const uuid = value => typeof value === 'string' && UUID.test(value);
const hash = value => typeof value === 'string' && HASH.test(value);
const ids = value => Array.isArray(value) && value.length <= 32 &&
  value.every(id => typeof id === 'string' && THREAD.test(id)) && new Set(value).size === value.length;

function absolute(filename) {
  if (typeof filename !== 'string' || !path.isAbsolute(filename) || path.resolve(filename) !== filename ||
      filename === path.parse(filename).root) fail('invalid-path');
  return filename;
}

async function privateDirectory(directory, create = false) {
  absolute(directory);
  let current = path.parse(directory).root;
  for (const part of directory.split(path.sep).filter(Boolean)) {
    current = path.join(current, part);
    let stat;
    try { stat = await fs.lstat(current); } catch (error) {
      if (error.code !== 'ENOENT' || current !== directory || !create) throw error;
      try { await fs.mkdir(current, { mode: 0o700 }); } catch (error) { if (error.code !== 'EEXIST') throw error; }
      stat = await fs.lstat(current);
    }
    const stickyAncestor = current !== directory && stat.uid === 0 && (stat.mode & 0o1000) !== 0;
    if (!stat.isDirectory() || stat.isSymbolicLink() || (stat.uid !== process.getuid() && stat.uid !== 0) ||
        ((stat.mode & 0o022) !== 0 && !stickyAncestor)) fail('unsafe-directory');
    if (current === directory && (stat.uid !== process.getuid() || (stat.mode & 0o7777) !== 0o700)) fail('unsafe-directory');
  }
}

function privateFile(stat, kind) {
  if (!(kind === 'socket' ? stat.isSocket() : stat.isFile()) || stat.isSymbolicLink() ||
      stat.uid !== process.getuid() || (stat.mode & 0o7777) !== 0o600 || stat.nlink !== 1) fail('unsafe-file');
}
const inode = (left, right) => left.dev === right.dev && left.ino === right.ino;

async function readPrivate(filename, limit) {
  const before = await fs.lstat(filename);
  privateFile(before, 'file');
  const handle = await fs.open(filename, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = await handle.stat();
    privateFile(stat, 'file');
    if (!inode(before, stat)) fail('file-replaced');
    if (stat.size > limit) fail('file-too-large');
    const buffer = Buffer.alloc(limit + 1);
    let length = 0;
    while (length < buffer.length) {
      const { bytesRead } = await handle.read(buffer, length, buffer.length - length, null);
      if (!bytesRead) break;
      length += bytesRead;
    }
    if (length > limit) fail('file-too-large');
    const after = await fs.lstat(filename);
    privateFile(after, 'file');
    if (!inode(stat, after)) fail('file-replaced');
    try { return new TextDecoder('utf-8', { fatal: true }).decode(buffer.subarray(0, length)); }
    catch { fail('invalid-utf8'); }
  } finally { await handle.close(); }
}

function instanceValid(value) {
  return only(value, INSTANCE_KEYS) && Object.keys(value).length === INSTANCE_KEYS.length &&
    uuid(value.instanceId) && sequence(value.pid) && typeof value.startedAt === 'string' &&
    value.startedAt.length <= 40 && Number.isFinite(Date.parse(value.startedAt)) &&
    hash(value.workspaceIdentity) && Array.isArray(value.workspaceUris) && value.workspaceUris.length <= 32 &&
    value.workspaceUris.every(uri => {
      if (typeof uri !== 'string' || uri.length > 2048) return false;
      try { const u = new URL(uri); return u.protocol === 'file:' && !u.hostname && !u.username && !u.password && !u.search && !u.hash; }
      catch { return false; }
    }) && [value.app, value.vscodeVersion].every(text => typeof text === 'string' && /^[\w .()+-]{1,80}$/.test(text));
}

function effectRequest(value) {
  if (!only(value, ['instanceId', 'effectSequence', 'operationId', 'action', 'target']) ||
      !uuid(value.instanceId) || !uuid(value.operationId) || !sequence(value.effectSequence) ||
      !EFFECT_ACTIONS.includes(value.action) ||
      !only(value.target, ['threadId', 'expectedSelection', 'workspaceIdentity']) ||
      typeof value.target.threadId !== 'string' || !THREAD.test(value.target.threadId) ||
      !ids(value.target.expectedSelection) || !hash(value.target.workspaceIdentity)) fail('invalid-intent');
  return { schema: 2, instanceId: value.instanceId, operationId: value.operationId,
    action: value.action, effectSequence: value.effectSequence,
    target: { workspaceIdentity: value.target.workspaceIdentity, threadId: value.target.threadId,
      expectedSelection: [...value.target.expectedSelection] } };
}

function validateReceipt(value, request, instance) {
  const readOnly = READ_ACTIONS.includes(request.action);
  const base = ['schema', 'status', 'code', 'messagesSent', 'menuObserved', 'operationId'];
  const extras = readOnly ? ['instance', 'selectedIds', 'capabilities', 'nextEffectSequence'] :
    ['effectSequence', 'nextEffectSequence', 'selectedIds', 'targetSelected', 'selectionMatchesTarget', 'nativeUiVerified'];
  if (!only(value, [...base, ...extras]) || value.schema !== 2 || value.operationId !== request.operationId ||
      value.messagesSent !== 0 || value.menuObserved !== false || typeof value.code !== 'string' ||
      typeof value.status !== 'string' ||
      !Object.hasOwn(RESPONSE_CODES, value.status) || !RESPONSE_CODES[value.status].includes(value.code)) fail('invalid-response');
  if (!readOnly && (value.effectSequence !== request.effectSequence ||
      !(value.nextEffectSequence === null || sequence(value.nextEffectSequence)))) fail('invalid-response');
  if (!readOnly && !UNCERTAIN_CODES.has(value.code) &&
      value.nextEffectSequence !== (request.effectSequence === Number.MAX_SAFE_INTEGER ? null : request.effectSequence + 1)) fail('invalid-response');
  if (value.status === 'observed') {
    if (!readOnly || value.code !== 'selection-read' || !instanceValid(value.instance) ||
        !INSTANCE_KEYS.every(key => same(value.instance[key], instance[key])) || !ids(value.selectedIds) ||
        !(value.nextEffectSequence === null || sequence(value.nextEffectSequence)) ||
        !Array.isArray(value.capabilities) || value.capabilities.length !== ACTIONS.length) fail('identity-or-observation-mismatch');
    const seen = new Set();
    for (const item of value.capabilities) {
      if (!only(item, ['action', 'registered', 'supported', 'runtimeVerified']) || !ACTIONS.includes(item.action) ||
          seen.has(item.action) || !['registered', 'supported', 'runtimeVerified'].every(key => typeof item[key] === 'boolean') ||
          (item.supported && !item.registered) ||
          (READ_ACTIONS.includes(item.action) && (!item.runtimeVerified || !item.supported)) ||
          (!READ_ACTIONS.includes(item.action) && item.runtimeVerified) ||
          (!READ_ACTIONS.includes(item.action) && !EFFECT_ACTIONS.includes(item.action) && item.supported)) fail('invalid-capabilities');
      seen.add(item.action);
    }
  } else if (value.status === 'commandCompleted') {
    if (readOnly || value.code !== 'native-readback' || !ids(value.selectedIds) || value.nativeUiVerified !== false ||
        value.targetSelected !== value.selectedIds.includes(request.target.threadId) ||
        value.selectionMatchesTarget !== same(value.selectedIds, [request.target.threadId])) fail('invalid-response');
  } else if ([...(readOnly ? ['nextEffectSequence'] : []), 'instance', 'selectedIds', 'capabilities', 'targetSelected', 'selectionMatchesTarget', 'nativeUiVerified']
    .some(key => Object.hasOwn(value, key))) fail('invalid-response');
  return value;
}

function journalName(request) {
  return `${request.instanceId}.${request.effectSequence}.${request.operationId}.jsonl`;
}

class CursorDesktopClient {
  #stateRoot;
  #discoveryRoot;
  #timeoutMs;
  #closed = false;
  #sockets = new Set();
  #pending = new Set();

  constructor({ stateRoot, testDiscoveryRoot, timeoutMs = 5000 } = {}) {
    if (!process.getuid || process.platform === 'win32') fail('unix-required');
    this.#stateRoot = absolute(stateRoot);
    this.#discoveryRoot = absolute(testDiscoveryRoot || path.join(os.homedir(), '.ccr-cursor-desktop'));
    if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 60000) fail('invalid-timeout');
    this.#timeoutMs = timeoutMs;
  }

  async #descriptor(instanceId) {
    if (typeof instanceId !== 'string' || !UUID.test(instanceId)) fail('invalid-instance');
    await privateDirectory(this.#discoveryRoot);
    const directory = path.join(this.#discoveryRoot, instanceId);
    await privateDirectory(directory);
    let discovery;
    try { discovery = JSON.parse(await readPrivate(path.join(directory, 'discovery.json'), LIMITS.discoveryBytes)); }
    catch (error) { if (error instanceof SyntaxError) fail('invalid-discovery'); throw error; }
    if (!only(discovery, ['schema', ...INSTANCE_KEYS, 'socketPath']) || discovery.schema !== 2 ||
        discovery.instanceId !== instanceId) fail('invalid-discovery');
    const instance = Object.fromEntries(INSTANCE_KEYS.map(key => [key, discovery[key]]));
    if (!instanceValid(instance)) fail('invalid-discovery');
    const socketPath = path.join(directory, 'rpc.sock');
    if (discovery.socketPath !== socketPath || Buffer.byteLength(socketPath) > 103) fail('unsafe-socket-path');
    const socketStat = await fs.lstat(socketPath);
    privateFile(socketStat, 'socket');
    return { instance, socketPath, socketStat };
  }

  async discover() {
    if (this.#closed) fail('client-closed');
    try { await privateDirectory(this.#discoveryRoot); } catch (error) {
      if (error.code === 'ENOENT') return { instances: [], rejected: [] };
      throw error;
    }
    const instances = [], rejected = [];
    const directory = await fs.opendir(this.#discoveryRoot);
    let count = 0;
    for await (const entry of directory) {
      if (!UUID.test(entry.name)) continue;
      if (++count > LIMITS.instances) fail('too-many-instances');
      try { instances.push((await this.#descriptor(entry.name)).instance); }
      catch (error) { rejected.push({ instanceId: entry.name, code: error.code || 'invalid-discovery' }); }
    }
    return { instances, rejected };
  }

  #run(instanceId, work) {
    if (this.#closed) return Promise.reject(new CursorDesktopClientError('client-closed'));
    if (typeof instanceId !== 'string' || !UUID.test(instanceId)) return Promise.reject(new CursorDesktopClientError('invalid-instance'));
    const key = `${this.#discoveryRoot}\n${instanceId}`;
    if (busyInstances.has(key)) return Promise.reject(new CursorDesktopClientError('client-busy'));
    busyInstances.add(key);
    const pending = Promise.resolve().then(work).finally(() => {
      busyInstances.delete(key);
      this.#pending.delete(pending);
    });
    this.#pending.add(pending);
    return pending;
  }

  async #exchange(descriptor, request) {
    if (this.#closed) fail('client-closed');
    const body = JSON.stringify(request) + '\n';
    if (Buffer.byteLength(body) > LIMITS.requestBytes) fail('request-too-large');
    return new Promise((resolve, reject) => {
      const socket = net.createConnection({ path: descriptor.socketPath, allowHalfOpen: true });
      this.#sockets.add(socket);
      let buffer = Buffer.alloc(0), settled = false;
      const finish = (error, value) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        socket.destroy();
        this.#sockets.delete(socket);
        if (error) reject(error); else resolve(value);
      };
      const timer = setTimeout(() => finish(new CursorDesktopClientError('socket-timeout')), this.#timeoutMs);
      socket.on('error', () => finish(new CursorDesktopClientError('socket-failed')));
      socket.on('close', () => finish(new CursorDesktopClientError(this.#closed ? 'client-closed' : 'socket-closed')));
      socket.on('connect', async () => {
        try {
          const current = await this.#descriptor(request.instanceId);
          if (!inode(current.socketStat, descriptor.socketStat) ||
              !same(current.instance, descriptor.instance)) fail('instance-changed');
          if (!settled && !this.#closed) socket.end(body);
          else finish(new CursorDesktopClientError('client-closed'));
        } catch (error) { finish(error); }
      });
      socket.on('data', chunk => {
        if (buffer.length + chunk.length > LIMITS.responseBytes) return finish(new CursorDesktopClientError('response-too-large'));
        buffer = Buffer.concat([buffer, chunk]);
      });
      socket.on('end', () => {
        try {
          if (!buffer.length || buffer[buffer.length - 1] !== 10 || buffer.indexOf(10) !== buffer.length - 1) fail('invalid-frame');
          const text = new TextDecoder('utf-8', { fatal: true }).decode(buffer.subarray(0, -1));
          finish(null, validateReceipt(JSON.parse(text), request, descriptor.instance));
        } catch (error) { finish(error instanceof CursorDesktopClientError ? error : new CursorDesktopClientError('invalid-response')); }
      });
    });
  }

  async #observation(instanceId, action) {
    const descriptor = await this.#descriptor(instanceId);
    const receipt = await this.#exchange(descriptor, { schema: 2, instanceId, operationId: randomUUID(), action,
      target: { workspaceIdentity: descriptor.instance.workspaceIdentity } });
    if (receipt.status !== 'observed') throw new CursorDesktopClientError(receipt.code, receipt);
    return { instance: descriptor.instance, selectedIds: receipt.selectedIds,
      nextEffectSequence: receipt.nextEffectSequence, receipt };
  }

  probe(instanceId) { return this.#run(instanceId, () => this.#observation(instanceId, 'probe')); }
  observe(instanceId) { return this.#run(instanceId, () => this.#observation(instanceId, 'read-selection')); }

  async #journals() {
    await privateDirectory(this.#stateRoot, true);
    const directory = await fs.opendir(this.#stateRoot);
    const filenames = [];
    for await (const entry of directory) {
      if (!entry.name.endsWith('.jsonl')) continue;
      if (filenames.length >= LIMITS.intents) fail('too-many-intents');
      filenames.push(entry.name);
    }
    return filenames;
  }

  async #readIntent(filename) {
    const text = await readPrivate(path.join(this.#stateRoot, filename), LIMITS.journalBytes);
    const lines = text.split('\n');
    let intent;
    try { intent = JSON.parse(lines[0]); } catch { fail('invalid-journal'); }
    if (!only(intent, ['instanceId', 'effectSequence', 'operationId', 'action', 'target', 'phase', 'receipt']) ||
        intent.phase !== 'unconfirmed' || intent.receipt !== null) fail('invalid-journal');
    const request = effectRequest(Object.fromEntries(['instanceId', 'effectSequence', 'operationId', 'action', 'target'].map(key => [key, intent[key]])));
    if (journalName(request) !== filename) fail('invalid-journal');
    for (const line of lines.slice(1, -1)) {
      try {
        const entry = JSON.parse(line);
        if (!only(entry, ['phase', 'receipt']) || !['confirmed', 'unconfirmed'].includes(entry.phase)) fail('invalid-journal');
        validateReceipt(entry.receipt, request);
        if (entry.phase !== this.#receiptPhase(entry.receipt)) fail('invalid-journal');
        intent = { ...intent, ...entry };
      } catch { return { ...intent, phase: 'unconfirmed', receipt: null, issue: 'journal-incomplete' }; }
    }
    if (lines[lines.length - 1] !== '') return { ...intent, phase: 'unconfirmed', receipt: null, issue: 'journal-incomplete' };
    return intent;
  }

  async listIntents() {
    const intents = [];
    for (const filename of await this.#journals()) intents.push(await this.#readIntent(filename));
    return intents;
  }

  async getIntent(instanceId, effectSequence, operationId) {
    if (!uuid(instanceId) || !uuid(operationId) || !sequence(effectSequence)) fail('invalid-intent');
    await privateDirectory(this.#stateRoot, true);
    return this.#readIntent(journalName({ instanceId, effectSequence, operationId }));
  }

  async #exclusive(work) {
    await privateDirectory(this.#stateRoot, true);
    // ponytail: 원장 전체 operationId 중복을 막기 위해 stateRoot의 효과를 직렬화한다.
    const filename = path.join(this.#stateRoot, '.effects.lock');
    let handle;
    try { handle = await fs.open(filename, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600); }
    catch (error) { if (error.code === 'EEXIST') fail('state-busy'); throw error; }
    const stat = await handle.stat();
    try {
      await handle.writeFile(JSON.stringify({ ownerId: randomUUID() }) + '\n');
      await handle.sync();
      return await work();
    } finally {
      await handle.close();
      const current = await fs.lstat(filename);
      privateFile(current, 'file');
      if (!inode(stat, current)) fail('state-lock-replaced');
      await fs.unlink(filename);
    }
  }

  #receiptPhase(receipt) {
    return receipt.status === 'indeterminate' || UNCERTAIN_CODES.has(receipt.code) ? 'unconfirmed' : 'confirmed';
  }

  async #saveReceipt(filename, receipt) {
    await privateDirectory(this.#stateRoot);
    const before = await fs.lstat(filename);
    privateFile(before, 'file');
    const handle = await fs.open(filename, constants.O_WRONLY | constants.O_APPEND | constants.O_NOFOLLOW);
    try {
      const stat = await handle.stat();
      privateFile(stat, 'file');
      if (!inode(before, stat)) fail('file-replaced');
      const line = JSON.stringify({ phase: this.#receiptPhase(receipt), receipt }) + '\n';
      if (stat.size + Buffer.byteLength(line) > LIMITS.journalBytes) fail('journal-full');
      await handle.writeFile(line);
      await handle.sync();
    } finally { await handle.close(); }
  }

  executeEffect(value) {
    let request;
    try { request = effectRequest(value); } catch (error) { return Promise.reject(error); }
    return this.#run(request.instanceId, () => this.#exclusive(async () => {
      const intents = await this.listIntents();
      if (intents.length >= LIMITS.intents) fail('too-many-intents');
      if (intents.some(intent => intent.operationId === request.operationId ||
          (intent.instanceId === request.instanceId && intent.effectSequence === request.effectSequence))) fail('intent-exists');
      if (intents.some(intent => intent.instanceId === request.instanceId && intent.phase === 'unconfirmed')) fail('unconfirmed-intent');
      const observed = await this.#observation(request.instanceId, 'probe');
      if (observed.instance.workspaceIdentity !== request.target.workspaceIdentity) fail('workspace-mismatch');
      if (observed.nextEffectSequence !== request.effectSequence) fail('stale-effect-sequence');
      const descriptor = await this.#descriptor(request.instanceId);
      if (!same(descriptor.instance, observed.instance)) fail('instance-changed');
      const { schema, ...intent } = request;
      const filename = path.join(this.#stateRoot, journalName(request));
      const handle = await fs.open(filename, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
      try {
        await handle.writeFile(JSON.stringify({ ...intent, phase: 'unconfirmed', receipt: null }) + '\n');
        await handle.sync();
      } finally { await handle.close(); }
      // 파일과 디렉터리 영속화를 끝낸 뒤에만 효과를 전송한다.
      const directory = await fs.open(this.#stateRoot, constants.O_RDONLY | constants.O_NOFOLLOW);
      try { await directory.sync(); } finally { await directory.close(); }
      return this.#sendIntent(request, descriptor, filename);
    }));
  }

  async #sendIntent(request, descriptor, filename) {
    try {
      const receipt = await this.#exchange(descriptor, request);
      await this.#saveReceipt(filename, receipt);
      return await this.#readIntent(path.basename(filename));
    } catch (error) {
      const intent = await this.#readIntent(path.basename(filename));
      return { ...intent, phase: 'unconfirmed', issue: error.code || 'effect-unconfirmed' };
    }
  }

  async checkReceipt(instanceId, effectSequence, operationId) {
    const intent = await this.getIntent(instanceId, effectSequence, operationId);
    return intent.phase === 'confirmed' ? intent : {
      ...intent, issue: intent.issue || 'remote-receipt-query-unsupported'
    };
  }

  replayOriginalEffect(instanceId, effectSequence, operationId) {
    return this.#run(instanceId, () => this.#exclusive(async () => {
      const intent = await this.getIntent(instanceId, effectSequence, operationId);
      if (intent.phase === 'confirmed') return intent;
      if (intent.issue) fail(intent.issue);
      const { phase, receipt, ...value } = intent;
      const request = effectRequest(value);
      const descriptor = await this.#descriptor(instanceId);
      if (descriptor.instance.workspaceIdentity !== request.target.workspaceIdentity) fail('workspace-mismatch');
      return this.#sendIntent(request, descriptor, path.join(this.#stateRoot, journalName(request)));
    }));
  }

  async close() {
    this.#closed = true;
    for (const socket of this.#sockets) socket.destroy();
    await Promise.allSettled([...this.#pending]);
  }
}

module.exports = { CursorDesktopClient, CursorDesktopClientError, EFFECT_ACTIONS, LIMITS };
