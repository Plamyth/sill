'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {canvasDiagramMarkdown} = require('./canvas-diagram');
const {MAX_CANVAS_SCENE_BYTES} = require('./canvas-scene');

const MAX_NOTE_BYTES = 1024 * 1024;
const MAX_ENTRIES = 500;
const UUID = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const MEMO_MARKER = '<!-- ccr:markdown-memo';
const MEMO_BOUNDARY = '\n<!-- ccr:markdown-memo:v1 -->\n';

function digest(bytes) { return crypto.createHash('sha256').update(bytes).digest('hex'); }

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
    const kind = node.kind === 'box' ? '상자' : node.kind === 'note' ? '메모' : '요소';
    const state = node.confidence === 'confirmed' ? '확정' : '확인 전 제안';
    const strokes = new Set((Array.isArray(node.sourceStrokeIds) ? node.sourceStrokeIds : [])
      .filter(id => typeof id === 'string' && UUID.test(id))).size;
    if (!append(`\n### ${kind} · ${node.id}\n\n<pre>${escaped(node.text)}</pre>\n\n${state} · 출처 획 ${strokes}개\n`)) break;
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

  save(relative, baseSha256, text) {
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
    const bytes = Buffer.from(text,'utf8');
    const temporary = path.join(path.dirname(file),`.ccr-${crypto.randomUUID()}.tmp`);
    const fd = fs.openSync(temporary,'wx',0o600);
    try { fs.writeFileSync(fd,bytes); fs.fsyncSync(fd); }
    finally { fs.closeSync(fd); }
    try {
      const latest = fs.existsSync(file) ? this.note(relative).sha256 : null;
      if (latest !== baseSha256) throw new VaultError('Note changed on Mac; reload before saving',409);
      fs.renameSync(temporary,file);
      const directoryFd = fs.openSync(path.dirname(file),'r');
      try { fs.fsyncSync(directoryFd); } finally { fs.closeSync(directoryFd); }
    } finally { if (fs.existsSync(temporary)) fs.unlinkSync(temporary); }
    return this.note(relative);
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
      let fd;
      try { fd = fs.openSync(asset,fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW); }
      catch (error) {
        if (['ENOENT','ELOOP'].includes(error.code))
          throw new VaultError('Canvas asset is missing or linked; manual reconciliation required',409);
        throw error;
      }
      let content;
      try { content = fs.readFileSync(fd); } finally { fs.closeSync(fd); }
      if (content.length > limit || digest(content) !== hash)
        throw new VaultError('Canvas asset does not match its note',409);
      if (extension === 'json') bytes = content;
    }
    const scene = JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
    if (scene.id?.toLowerCase() !== id || scene.revision !== revision)
      throw new VaultError('Canvas scene identity differs from its note',409);
    const legacy = canvasMarkdown(id,revision,sceneSha256,imageSha256);
    const structured = legacy + canvasStructure(scene);
    if (managed !== legacy && managed !== structured && managed !== structured + canvasDiagramMarkdown(scene))
      throw new VaultError('Canvas note metadata was changed; manual reconciliation required',409);
    return {memo,snapshot:{path:note.path,noteSha256:note.sha256,sceneSha256,imageSha256,
      revision:scene.revision,sceneJSONBase64:bytes.toString('base64')}};
  }

  saveCanvas(id, revision, sceneBytes, imageBytes, baseSha256) {
    if (!UUID.test(id || '') || !Number.isSafeInteger(revision) || revision < 0 ||
        sceneBytes.length > MAX_CANVAS_SCENE_BYTES || imageBytes.length > 5*1024*1024)
      throw new VaultError('Invalid canvas scene');
    const scene = JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(sceneBytes));
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
    const memo = current ? this.#canvasSnapshot(normalized,current).memo : null;
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
        if (error.code !== 'EEXIST' || digest(fs.readFileSync(target)) !== digest(bytes)) throw error;
      }
    }
    const note = this.save(relative,baseSha256,text);
    return {path:relative,noteSha256:note.sha256,sceneSha256,imageSha256,revision};
  }
}

module.exports = {ObsidianVault,VaultError};
