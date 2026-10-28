'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const child = require('node:child_process');
const {canvasDiagramMarkdown} = require('./canvas-diagram');
const {assertInkScene,MAX_CANVAS_SCENE_BYTES} = require('./canvas-scene');

const MAX_NOTE_BYTES = 1024 * 1024;
const MAX_ENTRIES = 500;
const UUID = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const MEMO_MARKER = '<!-- ccr:markdown-memo';
const MEMO_BOUNDARY = '\n<!-- ccr:markdown-memo:v1 -->\n';

function digest(bytes) { return crypto.createHash('sha256').update(bytes).digest('hex'); }

function durableFile(file, bytes) {
  const fd = fs.openSync(file,'wx',0o600);
  try { fs.writeFileSync(fd,bytes); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}

function syncDirectory(directory) {
  const fd = fs.openSync(directory,'r');
  try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}

function readAsset(file, limit, expectedHash) {
  let fd;
  try {
    fd = fs.openSync(file,fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    const stat = fs.fstatSync(fd);
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
  constructor(message, status = 400) { super(message); this.status = status; }
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
    if (!fs.statSync(this.root).isDirectory()) throw new VaultError('Vault root is not a directory');
  }

  resolve(relative, {directory = false, allowMissing = false} = {}) {
    if (typeof relative !== 'string' || relative.length > 1024 || relative.includes('\\') ||
        relative.includes('\0') || relative.startsWith('/') ||
        (relative && relative.split('/').some(part => !part || part === '.' || part === '..' || part.startsWith('.'))))
      throw new VaultError('Invalid vault path');
    if (!directory && (!relative.endsWith('.md') || !relative))
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
        (item.isDirectory() || item.isFile() && item.name.endsWith('.md')))
      .slice(0,MAX_ENTRIES + 1)
      .map(item => ({name:item.name,path:relative ? `${relative}/${item.name}` : item.name,
        kind:item.isDirectory() ? 'directory' : 'note'}));
  }

  note(relative) {
    const file = this.resolve(relative);
    const fd = fs.openSync(file,fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    try {
      const stat = fs.fstatSync(fd);
      if (!stat.isFile() || stat.size > MAX_NOTE_BYTES) throw new VaultError('Note exceeds 1 MiB',413);
      const bytes = fs.readFileSync(fd);
      const text = new TextDecoder('utf-8',{fatal:true,ignoreBOM:true}).decode(bytes);
      return {path:relative,text,sha256:digest(bytes),modifiedAt:stat.mtime.toISOString()};
    } finally { fs.closeSync(fd); }
  }

  save(relative, baseSha256, text, verify = () => {}) {
    if (typeof text !== 'string' || Buffer.byteLength(text,'utf8') > MAX_NOTE_BYTES)
      throw new VaultError('Note exceeds 1 MiB',413);
    if (baseSha256 !== null && !/^[0-9a-f]{64}$/.test(baseSha256 || ''))
      throw new VaultError('Invalid base version');
    const file = this.resolve(relative,{allowMissing:baseSha256 === null});
    let current = null;
    try { current = this.note(relative); }
    catch (error) { if (error.status !== 404) throw error; }
    if ((current?.sha256 ?? null) !== baseSha256)
      throw new VaultError('Note changed on Mac; reload before saving',409);
    const bytes = Buffer.from(text,'utf8'),proposalHash = digest(bytes);
    const recovery = path.join(path.dirname(file),`.ccr-save-${crypto.randomUUID()}`);
    fs.mkdirSync(recovery,0o700);
    if (current) durableFile(path.join(recovery,'base.md'),Buffer.from(current.text,'utf8'));
    durableFile(path.join(recovery,'proposal.md'),bytes);
    const displaced = path.join(recovery,'displaced.md');
    durableFile(displaced,bytes);
    syncDirectory(recovery);
    syncDirectory(path.dirname(file));
    const recoveryPath = path.relative(this.root,recovery);
    let attempted = false,outcome = 'prepared';
    try {
      let latest = null;
      try { latest = this.note(relative).sha256; } catch (error) { if (error.status !== 404) throw error; }
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
      const saved = new ObsidianVault(this.root).note(relative);
      if (saved.sha256 !== proposalHash) throw new VaultError('저장 전환 뒤 외부 메모가 바뀌었습니다.',409);
      verify(saved);
      if (current && digest(readAsset(displaced,MAX_NOTE_BYTES)) !== baseSha256)
        throw new VaultError('보존된 외부 메모가 저장 검사 중 바뀌었습니다.',409);
      outcome = 'published-verified';
      return saved;
    } catch (error) {
      outcome = 'conflict-preserved';
      const reason = error instanceof VaultError ? error.message : '파일 교환 또는 저장 검증을 끝내지 못했습니다.';
      throw new VaultError(`${reason} 원본·외부 변경·제안본을 ${recoveryPath}에 보존했습니다. 활성 경로를 자동 복구하지 않습니다.`,409);
    } finally {
      durableFile(path.join(recovery,'receipt.json'),Buffer.from(JSON.stringify({
        schema:'ccr.note-save-preservation/v1',path:relative,baseSha256,proposalSha256:proposalHash,
        publicationAttempted:attempted,outcome,absoluteCAS:false,
        publicationPrimitive:current ? 'atomic-exchange-retaining-displaced-inode' : 'exclusive-hard-link',
        automaticRollback:false,
        files:{base:current ? 'base.md' : null,proposal:'proposal.md',displaced:'displaced.md'},
        lateExternalWrites:'displaced inode retained; no future-writer exclusion claimed'
      })+'\n'));
      syncDirectory(recovery);
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
      const reopened = new ObsidianVault(this.root).canvas(id);
      if (reopened.noteSha256 !== saved.sha256 || reopened.sceneSha256 !== sceneSha256 || reopened.imageSha256 !== imageSha256)
        throw new VaultError('저장한 그림을 새 인스턴스에서 확인하지 못했습니다.',409);
    });
    return {path:relative,noteSha256:note.sha256,sceneSha256,imageSha256,revision};
  }
}

module.exports = {ObsidianVault,VaultError};
