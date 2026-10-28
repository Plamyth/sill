'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const child = require('node:child_process');
const {validPNG} = require('./canvas-png');
const {canvasDiagramMarkdown} = require('./canvas-diagram');
const {assertInkScene,MAX_CANVAS_SCENE_BYTES} = require('./canvas-scene');

const MAX_NOTE_BYTES = 1024 * 1024;
const MAX_ENTRIES = 500;
const MAX_PDF_BYTES = 20 * 1024 * 1024;
const UUID = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const MEMO_MARKER = '<!-- ccr:markdown-memo';
const MEMO_BOUNDARY = '\n<!-- ccr:markdown-memo:v1 -->\n';

function digest(bytes) { return crypto.createHash('sha256').update(bytes).digest('hex'); }

function durableFile(file, bytes, created = () => {}) {
  const fd = fs.openSync(file,'wx',0o600);
  try { created(); fs.writeFileSync(fd,bytes); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}

function syncDirectory(directory) {
  const fd = fs.openSync(directory,'r');
  try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}

function readAsset(file, limit, expectedHash, requireOwner = false, identity) {
  let fd;
  try {
    fd = fs.openSync(file,fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    const stat = fs.fstatSync(fd);
    if (identity && (stat.dev !== identity.dev || stat.ino !== identity.ino))
      throw new VaultError('메모 파일이 열리는 동안 바뀌었습니다.',409);
    if (requireOwner && stat.uid !== process.getuid()) throw new VaultError('메모 파일의 소유자가 다릅니다.',409);
    if (!stat.isFile() || stat.size > limit) throw new VaultError('그림 원본 파일이 크기 한도 안의 일반 파일이 아닙니다.',409);
    const buffer = Buffer.alloc(limit + 1);
    let length = 0, count;
    while (length < buffer.length && (count = fs.readSync(fd,buffer,length,buffer.length-length,null)) > 0) length += count;
    const bytes = buffer.subarray(0,length);
    if (length > limit || (expectedHash !== undefined && digest(bytes) !== expectedHash)) throw new VaultError('Canvas asset does not match its note',409);
    return bytes;
  } catch (error) {
    if (error instanceof VaultError) throw error;
    throw new VaultError('그림 원본 파일이 없거나 링크이거나 읽을 수 없습니다. 원본을 보존합니다.',409);
  } finally { if (fd !== undefined) fs.closeSync(fd); }
}


function canvasMarkdown(id, revision, sceneSha256, imageSha256) {
  const sceneAsset = `Assets/${id}-${sceneSha256}.json`;
  const imageAsset = `Assets/${id}-${imageSha256}.png`;
  return `---\nccr_scene_id: ${id}\nccr_revision: ${revision}\n` +
    `ccr_scene_sha256: ${sceneSha256}\nccr_image_sha256: ${imageSha256}\n---\n\n` +
    `# iPad 그림 ${id.slice(0,8)}\n\n![[${imageAsset}]]\n\n` +
    `원본 획과 구조: [[${sceneAsset}]]\n`;
}

function canvasStructure(scene) {
  const nodes = (Array.isArray(scene.nodes) ? scene.nodes : []).filter(node =>
    node && typeof node.id === 'string' && UUID.test(node.id) && typeof node.text === 'string');
  const links = (Array.isArray(scene.links) ? scene.links : []).filter(link =>
    link && typeof link.from === 'string' && typeof link.to === 'string' &&
    UUID.test(link.from) && UUID.test(link.to));
  if (!nodes.length && !links.length) return '';
  const escaped = text => text.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  const heading = '\n## 그림의 글자와 관계\n\n' +
    '그림판 또는 원본 구조 파일에서 수정하면 이 영역도 갱신됩니다.\n';
  const omitted = '\n일부 요소는 생략됐습니다. 전체 내용은 위 원본 구조 파일에 있습니다.\n';
  let text = heading, bytes = Buffer.byteLength(heading), remaining = false;
  const append = part => {
    const size = Buffer.byteLength(part);
    if (bytes + size + Buffer.byteLength(omitted) > 64*1024) { remaining = true; return false; }
    text += part; bytes += size; return true;
  };
  for (const node of nodes) {
    const kind = node.kind === 'box' ? '상자' : node.kind === 'note' ? '메모' :
      node.kind === 'ellipse' ? '타원' : node.kind === 'line' ? '선' : '요소';
    const state = node.confidence === 'confirmed' ? '확정' : '확인 전 제안';
    const strokes = new Set((Array.isArray(node.sourceStrokeIds) ? node.sourceStrokeIds : [])
      .filter(id => typeof id === 'string' && UUID.test(id))).size;
    const geometry = scene.schemaVersion === 3 ? `\n기하 정보: <code>${escaped(JSON.stringify({kind:node.kind,frame:node.frame,
      ...(node.rotationDegrees != null ? {rotationDegrees:node.rotationDegrees} : {})}))}</code>\n` : '';
    if (!append(`\n### ${kind} · ${node.id}\n\n<pre>${escaped(node.text)}</pre>\n\n${state} · 출처 획 ${strokes}개\n${geometry}`)) break;
  }
  if (!remaining && links.length) {
    append('\n### 연결\n');
    for (const link of links) {
      const kind = link.kind === 'parentChild' ? '부모·자식' : link.kind === 'arrow' ? '화살표' : '연결';
      if (!append(`\n- ${link.from} → ${link.to} · ${kind}\n`)) break;
    }
  }
  return text + (remaining ? omitted : '');
}

class VaultError extends Error {
  constructor(message, status = 400, details = {}) { super(message); this.status = status; Object.assign(this,details); }
}

function canvasNoteParts(text) {
  const boundary = text.indexOf(MEMO_BOUNDARY);
  const markers = text.split(MEMO_MARKER).length - 1;
  if (markers !== (boundary < 0 ? 0 : 1))
    throw new VaultError('Canvas memo marker is ambiguous or unsupported; preserve the note and reconcile manually',409);
  return boundary < 0 ? {managed:text,memo:null} :
    {managed:text.slice(0,boundary),memo:text.slice(boundary + MEMO_BOUNDARY.length)};
}

class ObsidianVault {
  constructor(root) {
    if (!path.isAbsolute(root || '')) throw new VaultError('Vault root must be absolute');
    this.root = fs.realpathSync(root);
    const rootStat = fs.statSync(this.root);
    if (!rootStat.isDirectory()) throw new VaultError('Vault root is not a directory');
    this.caseInsensitive = process.platform === 'darwin';
    for (let directory = this.root; path.dirname(directory) !== directory; directory = path.dirname(directory)) {
      const parent = path.dirname(directory);
      if (fs.statSync(parent).dev !== rootStat.dev) break;
      const name = path.basename(directory),alternate = name.replace(/[A-Za-z]/,letter =>
        letter === letter.toLowerCase() ? letter.toUpperCase() : letter.toLowerCase());
      if (alternate === name) continue;
      try {
        const actual = fs.statSync(directory),alias = fs.statSync(path.join(parent,alternate));
        this.caseInsensitive = actual.dev === alias.dev && actual.ino === alias.ino;
      } catch (error) { if (error.code !== 'ENOENT') throw error; this.caseInsensitive = false; }
      break;
    }
  }

  resolve(relative, {directory = false, allowMissing = false, pdf = false} = {}) {
    if (typeof relative !== 'string' || relative.length > 1024 || relative.includes('\\') ||
        relative.includes('\0') || relative.startsWith('/') ||
        (relative && relative.split('/').some(part => !part || part === '.' || part === '..' || part.startsWith('.'))))
      throw new VaultError('Invalid vault path');
    if (!directory && (!(pdf ? relative.endsWith('.pdf') : relative.endsWith('.md')) || !relative))
      throw new VaultError('Only Markdown notes can be edited');
    let current = this.root;
    const parts = relative ? relative.split('/') : [];
    for (let index = 0; index < parts.length; index++) {
      current = path.join(current,parts[index]);
      let stat;
      try { stat = fs.lstatSync(current); }
      catch (error) {
        if (error.code === 'ENOENT' && allowMissing && index === parts.length - 1) return current;
        if (error.code === 'ENOENT') throw new VaultError('Vault path not found',404);
        throw error;
      }
      if (stat.isSymbolicLink() || (index < parts.length - 1 && !stat.isDirectory()))
        throw new VaultError('Vault path contains a link or non-directory');
      if (index === parts.length - 1 && !(directory ? stat.isDirectory() : stat.isFile()))
        throw new VaultError('Vault path has the wrong file type');
    }
    return current;
  }

  entries(relative = '') {
    const directory = this.resolve(relative,{directory:true});
    return fs.readdirSync(directory,{withFileTypes:true})
      .filter(item => !item.name.startsWith('.') &&
        (item.isDirectory() || item.isFile() && /\.(md|pdf)$/.test(item.name)))
      .slice(0,MAX_ENTRIES + 1)
      .map(item => ({name:item.name,path:relative ? `${relative}/${item.name}` : item.name,
        kind:item.isDirectory() ? 'directory' : item.name.endsWith('.pdf') ? 'pdf' : 'note'}));
  }

  pdf(relative) {
    const file = this.resolve(relative,{pdf:true});
    const components = [this.root];
    for (const part of relative.split('/')) components.push(path.join(components.at(-1),part));
    const identities = components.map(component => {
      const stat = fs.lstatSync(component);
      if (stat.isSymbolicLink()) throw new VaultError('PDF path contains a link');
      return stat;
    });
    const samePath = () => components.every((component,index) => {
      const stat = fs.lstatSync(component), previous = identities[index];
      return !stat.isSymbolicLink() && stat.dev === previous.dev && stat.ino === previous.ino;
    });
    const fd = fs.openSync(file,fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    try {
      const before = fs.fstatSync(fd), expected = identities.at(-1);
      if (before.dev !== expected.dev || before.ino !== expected.ino || !samePath())
        throw new VaultError('PDF path changed during open',409);
      if (!before.isFile() || before.size > MAX_PDF_BYTES)
        throw new VaultError('PDF exceeds 20 MiB',413);
      const chunks = [];
      let total = 0;
      while (true) {
        const buffer = Buffer.alloc(Math.min(64 * 1024,MAX_PDF_BYTES + 1 - total));
        const count = fs.readSync(fd,buffer,0,buffer.length,null);
        if (!count) break;
        total += count;
        if (total > MAX_PDF_BYTES) throw new VaultError('PDF exceeds 20 MiB',413);
        chunks.push(buffer.subarray(0,count));
      }
      const bytes = Buffer.concat(chunks,total), after = fs.fstatSync(fd);
      if (!samePath() || before.size !== after.size || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs)
        throw new VaultError('PDF changed during read',409);
      if (bytes.subarray(0,5).toString('ascii') !== '%PDF-')
        throw new VaultError('Invalid PDF signature');
      return {path:relative,sha256:digest(bytes),dataBase64:bytes.toString('base64')};
    } finally { fs.closeSync(fd); }
  }

  #privateDirectory(directory) {
    const stat = fs.lstatSync(directory);
    if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid() || (stat.mode & 0o077))
      throw new VaultError('보존 원장이 소유자 전용 일반 디렉터리가 아닙니다.',409);
  }

  #record(file) {
    try { fs.lstatSync(file); } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
    try { return JSON.parse(readAsset(file,64*1024).toString('utf8')); }
    catch { throw new VaultError('보존 원장을 안전하게 읽을 수 없습니다.',409); }
  }

  #journals(relative) {
    const file = this.resolve(relative,{allowMissing:true}),directory = path.dirname(file),records = [];
    // ponytail: scan the existing append-only journal; an index is warranted if this bounded scan becomes a bottleneck.
    const entries = fs.readdirSync(directory);
    if (entries.length > 16384) throw new VaultError('보존 원장 목록의 검사 한도를 초과했습니다.',409);
    for (const name of entries.sort()) {
      if (!name.startsWith('.ccr-save-') || !UUID.test(name.slice(10))) continue;
      const folder = path.join(directory,name);
      this.#privateDirectory(folder);
      const intent = this.#record(path.join(folder,'intent.json'));
      const receipt = this.#record(path.join(folder,'receipt.json'));
      const record = intent ?? receipt;
      if (!record) continue;
      const key = value => this.caseInsensitive ? value.normalize('NFC').toLowerCase() : value;
      if (typeof record.path !== 'string') throw new VaultError('보존 원장의 노트 식별자가 없습니다.',409);
      if (key(record.path) !== key(relative)) continue;
      if (intent && (intent.schema !== 'ccr.note-save-intent/v1' || intent.vaultKey !== digest(Buffer.from(this.root))))
        throw new VaultError('보존 원장의 vault 식별자가 일치하지 않습니다.',409);
      if (receipt && receipt.schema !== 'ccr.note-save-preservation/v1')
        throw new VaultError('지원하지 않는 보존 원장입니다.',409);
      const recoveryID = name.slice(10),resolution = this.#record(path.join(folder,'resolution.json'));
      if (resolution && (!['ccr.canvas-resolution/v1','ccr.note-resolution/v1'].includes(resolution.schema) || resolution.recoveryID !== recoveryID ||
          typeof resolution.path !== 'string' || key(resolution.path) !== key(relative) || !/^[0-9a-f]{64}$/.test((resolution.schema === 'ccr.note-resolution/v1' ? resolution.result?.sha256 : resolution.result?.noteSha256) || '')))
        throw new VaultError('지원하지 않는 조정 기록입니다.',409);
      records.push({folder,recoveryID,intent,receipt,resolution});
    }
    const byID = new Map(records.map(record => [record.recoveryID,record])),children = new Set(),resolved = new Set();
    for (const record of records) {
      let current = record,seen = new Set();
      while (current.intent?.parentRecoveryID) {
        if (seen.has(current.recoveryID)) throw new VaultError('보존 원장의 계보가 순환합니다.',409);
        seen.add(current.recoveryID);
        const parent = current.intent.parentRecoveryID;
        if (!UUID.test(parent) || !byID.has(parent)) throw new VaultError('보존 원장의 부모가 이 노트에 없습니다.',409);
        children.add(parent);current = byID.get(parent);
      }
      if (record.resolution) {
        const saved = byID.get(record.resolution.savedJournalID);
        if (saved?.intent?.parentRecoveryID !== record.recoveryID || saved.receipt?.outcome !== 'published-verified')
          throw new VaultError('조정 완료 기록의 게시 원장이 일치하지 않습니다.',409);
        for (let item = saved; item; item = byID.get(item.intent?.parentRecoveryID)) resolved.add(item.recoveryID);
      }
    }
    for (const record of records) record.pending = !resolved.has(record.recoveryID) && !children.has(record.recoveryID) &&
      (Boolean(record.intent?.parentRecoveryID) || !['published-verified','not-published-verified'].includes(record.receipt?.outcome));
    return records;
  }

  #required(journal, message = '이 메모는 명시적인 충돌 조정이 필요합니다.') {
    return new VaultError(message,409,{code:'note_reconciliation_required',reconciliationRequired:true,
      recoveryID:journal.recoveryID,publicationAttempted:journal.receipt?.publicationAttempted ?? true});
  }

  #guard(relative) {
    const pending = this.#journals(relative).find(record => record.pending);
    if (pending) throw this.#required(pending);
  }

  #generalNotePath(relative) {
    const file = this.resolve(relative,{allowMissing:true});
    if (relative.split('/')[0].normalize('NFC').toLowerCase() === 'ccr canvas')
      throw new VaultError('관리되는 Canvas 노트는 Canvas 복구 경로를 사용해야 합니다.',409);
    const root = fs.lstatSync(this.root);
    if (!root.isDirectory() || root.isSymbolicLink() || root.uid !== process.getuid())
      throw new VaultError('Vault 소유자와 경로를 확인하지 못했습니다.',409);
    let stat;
    try { stat = fs.lstatSync(file); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (stat && (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== process.getuid()))
      throw new VaultError('복구 대상은 소유자의 일반 Markdown 파일이어야 합니다.',409);
    if (!stat || !fs.existsSync(path.join(this.root,'CCR Canvas'))) return relative;
    const folder = this.resolve('CCR Canvas',{directory:true}),entries = fs.readdirSync(folder);
    if (entries.length > 16384) throw new VaultError('Canvas 별칭 검사 한도를 초과했습니다.',409);
    for (const name of entries) {
      if (!/\.md$/i.test(name) || !UUID.test(name.slice(0,-3))) continue;
      const managed = fs.lstatSync(path.join(folder,name));
      if (managed.isFile() && managed.dev === stat.dev && managed.ino === stat.ino)
        throw new VaultError('관리되는 Canvas 파일의 별칭은 일반 메모로 복구할 수 없습니다.',409);
    }
    return relative;
  }

  #noteSnapshot(relative, note) {
    this.#generalNotePath(relative);
    const bytes = Buffer.from(note.text,'utf8');
    if (bytes.length > MAX_NOTE_BYTES || digest(bytes) !== note.sha256)
      throw new VaultError('메모 원문 바이트와 SHA가 일치하지 않습니다.',409);
    const frontmatter = /^\uFEFF?---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/.exec(note.text)?.[1];
    if (frontmatter && /^ccr_scene_id:/m.test(frontmatter))
      throw new VaultError('Canvas 원본 메타데이터는 Canvas 복구 검증을 거쳐야 합니다.',409);
    return {path:relative,sha256:note.sha256};
  }

  #ownedNoteBytes(file, limit = MAX_NOTE_BYTES) {
    const relative = path.relative(this.root,file);
    if (relative.startsWith('../') || path.isAbsolute(relative)) throw new VaultError('메모가 Vault 밖에 있습니다.',409);
    const components = [this.root];
    for (const part of relative.split(path.sep)) components.push(path.join(components.at(-1),part));
    const identities = components.map((component,index) => {
      const stat = fs.lstatSync(component);
      if (stat.isSymbolicLink() || stat.uid !== process.getuid() ||
          !(index === components.length-1 ? stat.isFile() : stat.isDirectory()))
        throw new VaultError('메모 경로의 종류와 소유자를 확인하지 못했습니다.',409);
      return stat;
    });
    const bytes = readAsset(file,limit,undefined,true,identities.at(-1));
    if (!components.every((component,index) => {
      const stat = fs.lstatSync(component),before = identities[index];
      return !stat.isSymbolicLink() && stat.uid === before.uid && stat.dev === before.dev && stat.ino === before.ino;
    })) throw new VaultError('메모를 읽는 동안 경로가 바뀌었습니다.',409);
    return bytes;
  }

  noteConflict(relative) {
    this.#generalNotePath(relative);
    const journal = this.#journals(relative).find(record => record.pending);
    if (!journal) throw new VaultError('조정이 필요한 메모가 없습니다.',404);
    return this.#conflictState(null,journal,relative);
  }

  resolveNoteConflict(relative, request) {
    this.#generalNotePath(relative);
    return this.#resolveConflict(relative,request);
  }

  #conflictState(id, journal, notePath = null) {
    const relative = notePath ?? `CCR Canvas/${id}.md`;
    const valid = notePath ? 'validNote' : 'validCanvas';
    const material = file => {
      try { fs.lstatSync(file); } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
      const bytes = notePath ? this.#ownedNoteBytes(file) : readAsset(file,MAX_NOTE_BYTES);
      const result = {sha256:digest(bytes),markdownBase64:bytes.toString('base64'),[valid]:false};
      try {
        const text = new TextDecoder('utf-8',{fatal:true,ignoreBOM:true}).decode(bytes);
        if (notePath) {
          this.#noteSnapshot(relative,{path:relative,text,sha256:result.sha256});
          result.validNote = true;return result;
        }
        const snapshot = this.#canvasSnapshot(id,{path:relative,text,sha256:result.sha256}).snapshot;
        const image = readAsset(path.join(this.root,'CCR Canvas/Assets',`${id}-${snapshot.imageSha256}.png`),5*1024*1024,snapshot.imageSha256);
        if (!validPNG(image)) throw new VaultError('Canvas preview is not a valid PNG',409);
        Object.assign(result,{validCanvas:true,canvas:snapshot,imagePNGBase64:image.toString('base64')});
      } catch (error) { result.refusal = error.message; }
      return result;
    };
    const materials = {active:material(this.resolve(relative,{allowMissing:true}))};
    for (const kind of ['base','displaced','proposal']) materials[kind] = material(path.join(journal.folder,`${kind}.md`));
    const records = this.#journals(relative),related = new Set([journal.recoveryID]);
    for (let changed = true; changed;) {
      changed = false;
      for (const record of records) {
        const parent = record.intent?.parentRecoveryID;
        if (parent && (related.has(parent) || related.has(record.recoveryID))) {
          if (!related.has(parent) || !related.has(record.recoveryID)) changed = true;
          related.add(parent);related.add(record.recoveryID);
        }
      }
    }
    const history = [];
    for (const record of records) {
      if (record.recoveryID === journal.recoveryID || !related.has(record.recoveryID)) continue;
      const files = {};
      for (const name of ['intent.json','base.md','displaced.md','proposal.md','receipt.json','receipt-unconfirmed.json','resolution-unconfirmed.json']) {
        const file = path.join(record.folder,name);
        try { fs.lstatSync(file); } catch (error) { if (error.code === 'ENOENT') { files[name] = null; continue; } throw error; }
        const limit = name.endsWith('.md') ? MAX_NOTE_BYTES : 64*1024;
        files[name] = digest(notePath ? this.#ownedNoteBytes(file,limit) : readAsset(file,limit));
      }
      history.push({recoveryID:record.recoveryID,files});
      if (history.length > 32) throw this.#required(journal,'조정 시도 보존 자료의 검사 한도를 초과했습니다. 자료를 유지합니다.');
    }
    const expected = {activeSha256:materials.active?.sha256 ?? null,baseSha256:materials.base?.sha256 ?? null,
      displacedSha256:materials.displaced?.sha256 ?? null,proposalSha256:materials.proposal?.sha256 ?? null,
      historySha256:digest(Buffer.from(JSON.stringify(history)))};
    const result = {schema:notePath ? 'ccr.note-conflict/v1' : 'ccr.canvas-conflict/v1',
      ...(notePath ? {path:relative} : {id}),recoveryID:journal.recoveryID,
      code:'note_reconciliation_required',reconciliationRequired:true,
      publicationAttempted:journal.receipt?.publicationAttempted ?? true,expected,materials,history};
    if (Buffer.byteLength(JSON.stringify(result)) > (notePath ? 8 : 64)*1024*1024)
      throw this.#required(journal,'충돌 자료 응답의 크기 한도를 초과했습니다. 원본은 유지합니다.');
    return result;
  }

  canvasConflict(id) {
    if (!UUID.test(id || '')) throw new VaultError('Invalid canvas ID');
    id = id.toLowerCase();
    const journal = this.#journals(`CCR Canvas/${id}.md`).find(record => record.pending);
    if (!journal) throw new VaultError('조정이 필요한 Canvas가 없습니다.',404);
    return this.#conflictState(id,journal);
  }

  resolveCanvasConflict(id, request) {
    if (!UUID.test(id || '')) throw new VaultError('Invalid canvas ID');
    id = id.toLowerCase();
    return this.#resolveConflict(`CCR Canvas/${id}.md`,request,id);
  }

  #resolveConflict(relative, request, id = null) {
    const stateFor = (vault,journal) => vault.#conflictState(id,journal,id ? null : relative);
    const snapshotFor = (vault,note) => id ? vault.#canvasSnapshot(id,note).snapshot : vault.#noteSnapshot(relative,note);
    const valid = id ? 'validCanvas' : 'validNote';
    const hashField = id ? 'noteSha256' : 'sha256';
    const keys = value => value && typeof value === 'object' && !Array.isArray(value) ? Object.keys(value).sort().join(',') : '';
    if (keys(request) !== 'decision,expected,recoveryID' || !UUID.test(request.recoveryID || '') || (!id && (typeof request.recoveryID !== 'string' || request.recoveryID !== request.recoveryID.toLowerCase())) ||
        !['keepCurrent','useDisplaced'].includes(request.decision) ||
        keys(request.expected) !== 'activeSha256,baseSha256,displacedSha256,historySha256,proposalSha256' ||
        !Object.entries(request.expected).every(([key,value]) => /^[0-9a-f]{64}$/.test(value || '') || key !== 'historySha256' && value === null))
      throw new VaultError('Invalid explicit reconciliation request');
    const journals = this.#journals(relative),journal = journals.find(record => record.recoveryID === request.recoveryID);
    if (!journal) throw new VaultError(id ? '복구 ID가 이 Canvas에 속하지 않습니다.' : '복구 ID가 이 메모에 속하지 않습니다.',409);
    const fingerprint = digest(Buffer.from(JSON.stringify({decision:request.decision,expected:
      Object.fromEntries(Object.entries(request.expected).sort(([a],[b]) => a.localeCompare(b)))})));
    const pending = journals.find(record => record.pending);
    if (journal.resolution) {
      if (pending) throw this.#required(pending);
      if (journal.resolution.fingerprint !== fingerprint || this.#rawNote(relative,!id).sha256 !== journal.resolution.result[hashField])
        throw new VaultError('이미 조정한 복구 ID의 결정 또는 현재 상태가 다릅니다.',409);
      const state = stateFor(this,journal);
      if (!state.materials.active?.[valid] || Object.keys(state.expected).some(key => state.expected[key] !== journal.resolution.finalExpected?.[key]))
        throw new VaultError('조정 결과 또는 보존 자료가 달라졌습니다.',409);
      return journal.resolution.result;
    }
    if (pending?.recoveryID !== journal.recoveryID) {
      if (pending) throw this.#required(pending);
      throw new VaultError('이 복구 ID는 뒤이은 명시 조정으로 종료됐습니다.',409);
    }
    const state = stateFor(this,journal);
    if (Object.keys(state.expected).some(key => state.expected[key] !== request.expected[key]))
      throw this.#required(journal,'현재 또는 보존 자료가 달라졌습니다. 새 자료를 확인해야 합니다.');
    const chosen = state.materials[request.decision === 'keepCurrent' ? 'active' : 'displaced'];
    if (!chosen?.[valid]) throw new VaultError(id ? '선택한 자료를 Canvas 원본·Markdown·PNG로 재열 수 없습니다.' : '선택한 자료를 일반 Markdown 원문으로 재열 수 없습니다.',409,
      {code:'reconciliation_candidate_invalid',reconciliationRequired:true,recoveryID:journal.recoveryID,
        publicationAttempted:journal.receipt?.publicationAttempted ?? true});
    if (state.history.length >= 32) throw this.#required(journal,'조정 시도 한도에 도달했습니다. 모든 자료를 유지합니다.');
    const attemptID = crypto.randomUUID(),attempt = path.join(path.dirname(journal.folder),`.ccr-save-${attemptID}`);
    let resolutionStarted = false;
    try {
      const validate = saved => {
        const fresh = new ObsidianVault(this.root),note = fresh.#rawNote(relative,!id);
        const reopened = snapshotFor(fresh,note);
        if (!id && !Buffer.from(note.text,'utf8').equals(Buffer.from(chosen.markdownBase64,'base64')))
          throw new VaultError('선택한 메모 원문 바이트가 다릅니다.',409);
        if (note.sha256 !== saved.sha256 || saved.sha256 !== chosen.sha256 ||
            (id && (reopened.sceneSha256 !== chosen.canvas.sceneSha256 || reopened.imageSha256 !== chosen.canvas.imageSha256)))
          throw new VaultError('선택한 Canvas의 재열기 결과가 다릅니다.',409);
        if (id) {
          const image = readAsset(path.join(this.root,'CCR Canvas/Assets',`${id}-${reopened.imageSha256}.png`),5*1024*1024,reopened.imageSha256);
          if (!validPNG(image)) throw new VaultError('선택한 PNG 원본을 검증하지 못했습니다.',409);
        }
        const after = stateFor(fresh,journal);
        for (const key of ['baseSha256','displacedSha256','proposalSha256'])
          if (after.expected[key] !== state.expected[key]) throw new VaultError('조정 중 보존 원본이 바뀌었습니다.',409);
        const previousHistory = after.history.filter(item => item.recoveryID !== attemptID);
        if (JSON.stringify(previousHistory) !== JSON.stringify(state.history)) throw new VaultError('조정 중 이전 시도가 바뀌었습니다.',409);
        if (fresh.#rawNote(relative,!id).sha256 !== chosen.sha256) throw new VaultError('조정 중 새 외부 편집이 생겼습니다.',409);
        if (fresh.#journals(relative).some(record => record.pending && record.recoveryID !== attemptID))
          throw new VaultError('다른 미조정 게시 원장이 있습니다.',409);
        return reopened;
      };
      const saved = this.#save(relative,state.expected.activeSha256,
        new TextDecoder('utf-8',{fatal:true,ignoreBOM:true}).decode(Buffer.from(chosen.markdownBase64,'base64')),validate,attempt,journal.recoveryID);
      const reopened = validate(saved);
      const {sceneJSONBase64,...metadata} = reopened;
      const result = {...metadata,recoveryID:journal.recoveryID,decision:request.decision,resolved:true,reconciliationRequired:false};
      durableFile(path.join(journal.folder,'resolution.json'),Buffer.from(JSON.stringify({schema:id ? 'ccr.canvas-resolution/v1' : 'ccr.note-resolution/v1',
        recoveryID:journal.recoveryID,savedJournalID:attemptID,path:relative,fingerprint,result,finalExpected:stateFor(this,journal).expected})+'\n'),
        () => { resolutionStarted = true; });
      syncDirectory(journal.folder);
      validate(saved);
      return result;
    } catch (error) {
      if (resolutionStarted && fs.existsSync(path.join(journal.folder,'resolution.json'))) {
        fs.renameSync(path.join(journal.folder,'resolution.json'),path.join(attempt,'resolution-unconfirmed.json'));
        syncDirectory(journal.folder);
      }
      const latest = this.#journals(relative).find(record => record.pending) ?? journal;
      throw this.#required(latest,`${error.message} 모든 조정 자료를 유지합니다.`);
    }
  }

  note(relative) {
    this.#guard(relative);
    return this.#rawNote(relative);
  }

  #rawNote(relative, requireOwner = false) {
    const file = this.resolve(relative);
    const fd = fs.openSync(file,fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    try {
      const stat = fs.fstatSync(fd);
      if (!stat.isFile() || stat.size > MAX_NOTE_BYTES) throw new VaultError('Note exceeds 1 MiB',413);
      if (requireOwner && stat.uid !== process.getuid()) throw new VaultError('메모 파일의 소유자가 다릅니다.',409);
      const bytes = requireOwner ? this.#ownedNoteBytes(file) : readAsset(file,MAX_NOTE_BYTES);
      const text = new TextDecoder('utf-8',{fatal:true,ignoreBOM:true}).decode(bytes);
      return {path:relative,text,sha256:digest(bytes),modifiedAt:stat.mtime.toISOString()};
    } finally { fs.closeSync(fd); }
  }

  save(relative, baseSha256, text, verify = () => {}) {
    this.#guard(relative);
    try { return this.#save(relative,baseSha256,text,verify); }
    catch (error) { this.#guard(relative); throw error; }
  }

  #save(relative, baseSha256, text, verify, recovery, parentRecoveryID) {
    if (typeof text !== 'string' || Buffer.byteLength(text,'utf8') > MAX_NOTE_BYTES)
      throw new VaultError('Note exceeds 1 MiB',413);
    if (baseSha256 !== null && !/^[0-9a-f]{64}$/.test(baseSha256 || ''))
      throw new VaultError('Invalid base version');
    const file = this.resolve(relative,{allowMissing:baseSha256 === null});
    let current = null;
    try { current = this.#rawNote(relative); }
    catch (error) { if (error.status !== 404) throw error; }
    if ((current?.sha256 ?? null) !== baseSha256)
      throw new VaultError('Note changed on Mac; reload before saving',409);
    const bytes = Buffer.from(text,'utf8'),proposalHash = digest(bytes);
    recovery ??= path.join(path.dirname(file),`.ccr-save-${crypto.randomUUID()}`);
    fs.mkdirSync(recovery,0o700);
    durableFile(path.join(recovery,'intent.json'),Buffer.from(JSON.stringify({
      schema:'ccr.note-save-intent/v1',path:relative,vaultKey:digest(Buffer.from(this.root)),
      ...(parentRecoveryID ? {parentRecoveryID} : {})
    })+'\n'));
    if (current) durableFile(path.join(recovery,'base.md'),Buffer.from(current.text,'utf8'));
    durableFile(path.join(recovery,'proposal.md'),bytes);
    const displaced = path.join(recovery,'displaced.md');
    durableFile(displaced,bytes);
    syncDirectory(recovery);
    syncDirectory(path.dirname(file));
    const recoveryID = path.basename(recovery).replace('.ccr-save-','');
    let attempted = false,outcome = 'prepared';
    try {
      let latest = null;
      try { latest = this.#rawNote(relative).sha256; } catch (error) { if (error.status !== 404) throw error; }
      if (latest !== baseSha256) throw new VaultError('Note changed on Mac; reload before saving',409);
      attempted = true;
      if (current) {
        child.execFileSync(process.platform === 'darwin' ? '/usr/bin/python3' : 'python3',
          [path.join(__dirname,'vault-note-exchange.py'),displaced,file],{stdio:'pipe',timeout:10000});
      } else fs.linkSync(displaced,file);
      syncDirectory(path.dirname(file));
      syncDirectory(recovery);
      if (current && digest(readAsset(displaced,MAX_NOTE_BYTES)) !== baseSha256)
        throw new VaultError('저장 전환 중 외부 메모가 바뀌었습니다.',409);
      const saved = new ObsidianVault(this.root).#rawNote(relative);
      if (saved.sha256 !== proposalHash) throw new VaultError('저장 전환 뒤 외부 메모가 바뀌었습니다.',409);
      verify(saved);
      if (current && digest(readAsset(displaced,MAX_NOTE_BYTES)) !== baseSha256)
        throw new VaultError('보존된 외부 메모가 저장 검사 중 바뀌었습니다.',409);
      outcome = 'published-verified';
      return saved;
    } catch (error) {
      outcome = attempted ? 'conflict-preserved' : 'not-published-verified';
      const reason = error instanceof VaultError ? error.message : '파일 교환 또는 저장 검증을 끝내지 못했습니다.';
      if (!attempted) throw new VaultError(reason,409);
      throw new VaultError(`${reason} 원본·외부 변경·제안본을 보존했습니다. 명시 조정이 필요합니다.`,409,{
        code:'note_reconciliation_required',reconciliationRequired:true,recoveryID,publicationAttempted:attempted});
    } finally {
      let receiptCreated = false;
      try {
        durableFile(path.join(recovery,'receipt.json'),Buffer.from(JSON.stringify({
        schema:'ccr.note-save-preservation/v1',path:relative,baseSha256,proposalSha256:proposalHash,
        publicationAttempted:attempted,outcome,absoluteCAS:false,
        publicationPrimitive:current ? 'atomic-exchange-retaining-displaced-inode' : 'exclusive-hard-link',
        automaticRollback:false,
        files:{base:current ? 'base.md' : null,proposal:'proposal.md',displaced:'displaced.md'},
        lateExternalWrites:'displaced inode retained; no future-writer exclusion claimed'
        })+'\n'),() => { receiptCreated = true; });
        syncDirectory(recovery);
      } catch (error) {
        if (receiptCreated) fs.renameSync(path.join(recovery,'receipt.json'),path.join(recovery,'receipt-unconfirmed.json'));
        throw new VaultError('저장 결과 원장의 내구성을 확인하지 못했습니다. 모든 자료를 유지합니다.',409,
          {code:'note_reconciliation_required',reconciliationRequired:true,recoveryID,publicationAttempted:attempted});
      }
    }
  }

  canvasDirectory() {
    for (const relative of ['CCR Canvas','CCR Canvas/Assets']) {
      const folder = path.join(this.root,relative);
      try { fs.mkdirSync(folder,0o700); }
      catch (error) { if (error.code !== 'EEXIST') throw error; }
      if (!fs.lstatSync(folder).isDirectory() || fs.lstatSync(folder).isSymbolicLink())
        throw new VaultError('Canvas folder is not a directory');
    }
  }

  canvas(id) {
    if (!UUID.test(id || '')) throw new VaultError('Invalid canvas ID');
    const relative = `CCR Canvas/${id.toLowerCase()}.md`;
    return this.#canvasSnapshot(id.toLowerCase(),this.note(relative)).snapshot;
  }

  #canvasSnapshot(id, note) {
    const {managed,memo} = canvasNoteParts(note.text);
    const sceneSha256 = /^ccr_scene_sha256: ([0-9a-f]{64})$/m.exec(managed)?.[1];
    const imageSha256 = /^ccr_image_sha256: ([0-9a-f]{64})$/m.exec(managed)?.[1];
    const revision = Number(/^ccr_revision: (\d+)$/m.exec(managed)?.[1]);
    if (!sceneSha256 || !imageSha256 || !Number.isSafeInteger(revision) || revision < 0)
      throw new VaultError('Canvas note metadata was changed; manual reconciliation required',409);
    this.resolve('CCR Canvas/Assets',{directory:true});
    let bytes;
    for (const [hash,extension,limit] of [[sceneSha256,'json',MAX_CANVAS_SCENE_BYTES],[imageSha256,'png',5*1024*1024]]) {
      const asset = path.join(this.root,'CCR Canvas','Assets',`${id}-${hash}.${extension}`);
      const content = readAsset(asset,limit,hash);
      if (extension === 'json') bytes = content;
    }
    const scene = JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
    try { assertInkScene(scene); } catch (error) { throw new VaultError(error.message,409); }
    if (scene.id?.toLowerCase() !== id || scene.revision !== revision)
      throw new VaultError('Canvas scene identity differs from its note',409);
    const legacy = canvasMarkdown(id,revision,sceneSha256,imageSha256);
    const structured = legacy + canvasStructure(scene);
    if (managed !== legacy && managed !== structured && managed !== structured + canvasDiagramMarkdown(scene))
      throw new VaultError('Canvas note metadata was changed; manual reconciliation required',409);
    return {memo,schemaVersion:scene.schemaVersion,snapshot:{path:note.path,noteSha256:note.sha256,sceneSha256,imageSha256,
      revision:scene.revision,sceneJSONBase64:bytes.toString('base64')}};
  }

  saveCanvas(id, revision, sceneBytes, imageBytes, baseSha256) {
    if (!UUID.test(id || '') || !Number.isSafeInteger(revision) || revision < 0 ||
        sceneBytes.length > MAX_CANVAS_SCENE_BYTES || imageBytes.length > 5*1024*1024)
      throw new VaultError('Invalid canvas scene');
    const scene = JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(sceneBytes));
    try { assertInkScene(scene); } catch (error) { throw new VaultError(error.message); }
    if (scene.id?.toLowerCase() !== id.toLowerCase() || scene.revision !== revision)
      throw new VaultError('Canvas scene identity differs from request');
    const normalized = id.toLowerCase();
    const sceneSha256 = digest(sceneBytes), imageSha256 = digest(imageBytes);
    const relative = `CCR Canvas/${normalized}.md`;
    const sceneAsset = `Assets/${normalized}-${sceneSha256}.json`;
    const imageAsset = `Assets/${normalized}-${imageSha256}.png`;
    let current = null;
    try { current = this.note(relative); }
    catch (error) { if (error.status !== 404) throw error; }
    if ((current?.sha256 ?? null) !== baseSha256)
      throw new VaultError('Note changed on Mac; reload before saving',409);
    // Only Markdown owns the suffix. A scene autosave never reconstructs its contents.
    const prior = current ? this.#canvasSnapshot(normalized,current) : null;
    if (prior?.schemaVersion === 3 && scene.schemaVersion !== 3)
      throw new VaultError('그림 형식을 이전 버전으로 낮출 수 없습니다. 원본을 보존합니다.',409);
    const memo = prior?.memo ?? null;
    const text = canvasMarkdown(normalized,revision,sceneSha256,imageSha256) + canvasStructure(scene) + canvasDiagramMarkdown(scene) +
      MEMO_BOUNDARY + (memo ?? '\n## 메모\n\n');
    if (Buffer.byteLength(text) > MAX_NOTE_BYTES)
      throw new VaultError('Canvas note is too large; preserve the memo and reconcile manually',409);
    this.canvasDirectory();
    for (const [file,bytes] of [[sceneAsset,sceneBytes],[imageAsset,imageBytes]]) {
      const target = path.join(this.root,'CCR Canvas',file);
      try {
        const fd = fs.openSync(target,'wx',0o600);
        try { fs.writeFileSync(fd,bytes); fs.fsyncSync(fd); }
        finally { fs.closeSync(fd); }
      } catch (error) {
        if (error.code !== 'EEXIST') throw error;
      }
    }
    for (const [file,hash,limit] of [[sceneAsset,sceneSha256,MAX_CANVAS_SCENE_BYTES],[imageAsset,imageSha256,5*1024*1024]])
      readAsset(path.join(this.root,'CCR Canvas',file),limit,hash);
    const note = this.save(relative,baseSha256,text,saved => {
      const fresh = new ObsidianVault(this.root);
      const reopened = fresh.#canvasSnapshot(normalized,fresh.#rawNote(relative)).snapshot;
      if (reopened.noteSha256 !== saved.sha256 || reopened.sceneSha256 !== sceneSha256 || reopened.imageSha256 !== imageSha256)
        throw new VaultError('저장한 그림을 새 인스턴스에서 확인하지 못했습니다.',409);
    });
    return {path:relative,noteSha256:note.sha256,sceneSha256,imageSha256,revision};
  }
}

module.exports = {ObsidianVault,VaultError};
