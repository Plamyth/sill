'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {VaultError} = require('./obsidian-vault');

const UUID = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const HASH = /^[0-9a-f]{64}$/;
const BLOCK_ID = /^[A-Za-z0-9-]+$/;
const MAX_NOTE_BYTES = 1024 * 1024;
const MARKER = /(?:^|[ \t])\^([A-Za-z0-9-]+)(?=[ \t]*\r?$)/gm;
const STRUCTURAL = /^(?:[ #>+*\-_=~`!\[\\:]|[0-9]+[.)](?:[ \t]|$))/;
const sha = text => crypto.createHash('sha256').update(text,'utf8').digest('hex');
const unsupported = () => new VaultError('Unsupported linked paragraph; reload or edit the note directly',422);

// Mirrors the conservative Swift VaultMarkdownBlocks grammar, with UTF-16 splice offsets.
function paragraph(text, blockID) {
  if (typeof blockID !== 'string' || !BLOCK_ID.test(blockID) || blockID.length > 1024)
    throw new VaultError('Invalid block ID');
  const matches = [...text.matchAll(MARKER)].filter(match => match[1] === blockID);
  if (!matches.length) throw new VaultError('Linked block not found',404);
  if (matches.length !== 1) throw new VaultError('Linked block marker is ambiguous',409);
  if (text.includes('<') || text.includes('%%') || text.includes('$$') || /\r(?!\n)/.test(text))
    throw unsupported();
  const lines = [];
  let offset = 0, frontmatter = false, fence = null;
  for (const raw of text.split('\n')) {
    if (offset >= text.length) break;
    const line = raw.endsWith('\r') ? raw.slice(0,-1) : raw;
    const trimmed = line.replace(/^[\t \u00a0\u1680\u2000-\u200a\u202f\u205f\u3000]+|[\t \u00a0\u1680\u2000-\u200a\u202f\u205f\u3000]+$/g,'');
    let excluded = frontmatter || fence !== null;
    if (offset === 0 && (trimmed === '---' || trimmed === '\ufeff---')) {
      frontmatter = true;
      excluded = true;
    } else if (frontmatter && (trimmed === '---' || trimmed === '...')) frontmatter = false;
    else if (!frontmatter) {
      const opening = /^(`{3,}|~{3,})/.exec(trimmed)?.[0];
      if (opening) {
        excluded = true;
        if (!fence) fence = opening;
        else if (opening[0] === fence[0] && opening.length >= fence.length && trimmed === opening) fence = null;
      }
    }
    lines.push({text:line,start:offset,blank:trimmed === '',excluded});
    offset += raw.length + 1;
  }
  let cursor = 0;
  while (cursor < lines.length) {
    if (lines[cursor].blank) { cursor++; continue; }
    const lower = cursor;
    while (cursor < lines.length && !lines[cursor].blank) cursor++;
    const chunk = lines.slice(lower,cursor), first = chunk[0], last = chunk.at(-1);
    if (chunk.some(line => line.excluded)) continue;
    const match = [...last.text.matchAll(MARKER)][0];
    if (!match || match.index === 0 || match[1] !== blockID) continue;
    const end = last.start + match.index;
    const quote = text.slice(first.start,end);
    if (!quote.split('\n').every(raw => {
      const line = raw.endsWith('\r') ? raw.slice(0,-1) : raw;
      return line.length && !line.startsWith('\ufeff') && !/[ \t]$/.test(line) &&
        !/[\t\r^`|<>\[\\]/.test(line) && !STRUCTURAL.test(line);
    })) continue;
    let following = cursor;
    while (following < lines.length && lines[following].blank) following++;
    if (lines[following]?.text.startsWith('^')) continue;
    const endings = text.match(/\r?\n/g) || [];
    if (endings.some(ending => ending !== endings[0])) throw unsupported();
    return {start:first.start,end,text:quote,lineEnding:endings[0] || '\n'};
  }
  throw unsupported();
}

function syncDirectory(directory) {
  const fd = fs.openSync(directory,'r');
  try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}

function writeReceipt(directory, receipt) {
  const temporary = path.join(directory,`${crypto.randomUUID()}.tmp`);
  const fd = fs.openSync(temporary,'wx',0o600);
  try { fs.writeFileSync(fd,JSON.stringify(receipt)); fs.fsyncSync(fd); }
  finally { fs.closeSync(fd); }
  try { fs.renameSync(temporary,path.join(directory,'receipt.json')); syncDirectory(directory); }
  finally { if (fs.existsSync(temporary)) fs.unlinkSync(temporary); }
}

class VaultBlockEdits {
  constructor(vault, store) {
    this.vault = vault;
    this.store = path.join(store,'.block-edits');
    try { fs.mkdirSync(this.store,0o700); }
    catch (error) { if (error.code !== 'EEXIST') throw error; }
    if (fs.lstatSync(this.store).isSymbolicLink() || !fs.lstatSync(this.store).isDirectory())
      throw new VaultError('Block edit store is not a directory',409);
    syncDirectory(store);
  }

  block(relative, blockID) {
    const note = this.vault.note(relative), block = paragraph(note.text,blockID);
    return {schemaVersion:1,blockID,text:block.text,quoteSha256:sha(block.text),note};
  }

  edit(relative, blockID, body) {
    const fields = ['schemaVersion','operationId','baseSha256','baseQuoteSha256','replacementText'];
    if (!body || body.schemaVersion !== 1 || typeof body.operationId !== 'string' || !UUID.test(body.operationId) ||
        typeof body.baseSha256 !== 'string' || !HASH.test(body.baseSha256) ||
        typeof body.baseQuoteSha256 !== 'string' || !HASH.test(body.baseQuoteSha256) ||
        typeof body.replacementText !== 'string' || Object.keys(body).some(key => !fields.includes(key)))
      throw new VaultError('Invalid block edit contract');
    const replacement = body.replacementText;
    if (Buffer.byteLength(replacement,'utf8') > MAX_NOTE_BYTES) throw new VaultError('Note exceeds 1 MiB',413);
    if (Buffer.from(replacement,'utf8').toString('utf8') !== replacement) throw unsupported();
    const operationId = body.operationId.toLowerCase();
    const directory = path.join(this.store,operationId);
    // Resolve on retries too; a receipt never bypasses current vault path validation.
    try { this.vault.resolve(relative); }
    catch (error) {
      if (error.status === 404 && fs.existsSync(directory))
        throw new VaultError('Block edit target is missing; outcome uncertain, do not reapply',409);
      throw error;
    }
    if (typeof blockID !== 'string' || !BLOCK_ID.test(blockID) || blockID.length > 1024)
      throw new VaultError('Invalid block ID');
    const requestSha256 = sha(JSON.stringify([relative,blockID,1,operationId,
      body.baseSha256,body.baseQuoteSha256,replacement]));
    if (fs.existsSync(directory)) return this.#reconcile(directory,requestSha256,relative,blockID,operationId);
    const current = this.block(relative,blockID);
    if (current.note.sha256 !== body.baseSha256 || current.quoteSha256 !== body.baseQuoteSha256)
      throw new VaultError('Note or quote changed; reload before saving',409);
    const block = paragraph(current.note.text,blockID);
    if (/\r(?!\n)/.test(replacement) || (replacement.match(/\r?\n/g) || []).some(ending => ending !== block.lineEnding))
      throw unsupported();
    let candidate;
    try { candidate = paragraph(`${replacement} ^${blockID}`,blockID); }
    catch { throw unsupported(); }
    if (candidate.start !== 0 || candidate.text !== replacement) throw unsupported();
    const text = current.note.text.slice(0,block.start) + replacement + current.note.text.slice(block.end);
    if (Buffer.byteLength(text,'utf8') > MAX_NOTE_BYTES) throw new VaultError('Note exceeds 1 MiB',413);
    const resultingBlock = paragraph(text,blockID);
    if (resultingBlock.text !== replacement) throw unsupported();
    const receipt = {schemaVersion:1,operationId,path:relative,blockID,requestSha256,state:'prepared',
      baseSha256:body.baseSha256,expectedSha256:sha(text),quoteSha256:sha(replacement)};
    try { fs.mkdirSync(directory,0o700); }
    catch (error) {
      if (error.code === 'EEXIST') return this.#reconcile(directory,requestSha256,relative,blockID,operationId);
      throw error;
    }
    syncDirectory(this.store);
    writeReceipt(directory,receipt);
    const note = this.vault.save(relative,body.baseSha256,text);
    if (note.sha256 !== receipt.expectedSha256 || this.vault.note(relative).sha256 !== receipt.expectedSha256)
      throw new VaultError('Block edit outcome uncertain; reconcile with the same operation ID',409);
    writeReceipt(directory,{...receipt,state:'committed'});
    return {schemaVersion:1,operationId,blockID,disposition:'committed',quoteSha256:receipt.quoteSha256,note};
  }

  #reconcile(directory, requestSha256, relative, blockID, operationId) {
    let receipt;
    try {
      if (fs.lstatSync(directory).isSymbolicLink() || !fs.lstatSync(directory).isDirectory()) throw new Error();
      const fd = fs.openSync(path.join(directory,'receipt.json'),fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
      try {
        if (!fs.fstatSync(fd).isFile() || fs.fstatSync(fd).size > 8192) throw new Error();
        receipt = JSON.parse(fs.readFileSync(fd,'utf8'));
      } finally { fs.closeSync(fd); }
    } catch { throw new VaultError('Block edit receipt incomplete; outcome uncertain, do not reapply',409); }
    if (receipt.requestSha256 !== requestSha256 || receipt.path !== relative || receipt.blockID !== blockID ||
        receipt.operationId !== operationId)
      throw new VaultError('Operation ID already binds a different block edit',409);
    if (receipt.schemaVersion !== 1 || !['prepared','committed'].includes(receipt.state) ||
        !HASH.test(receipt.baseSha256 || '') || !HASH.test(receipt.expectedSha256 || '') || !HASH.test(receipt.quoteSha256 || ''))
      throw new VaultError('Block edit receipt invalid; outcome uncertain',409);
    let current;
    try { current = this.block(relative,blockID); }
    catch { throw new VaultError('Block edit target changed or unavailable; outcome uncertain',409); }
    if (receipt.state === 'prepared' && current.note.sha256 === receipt.baseSha256)
      throw new VaultError('Prepared block edit still has its base; outcome uncertain, do not reapply',409);
    if (current.note.sha256 !== receipt.expectedSha256 || current.quoteSha256 !== receipt.quoteSha256)
      throw new VaultError('Block edit outcome conflicts or is uncertain; do not reapply',409);
    writeReceipt(directory,{...receipt,state:'committed'});
    return {schemaVersion:1,operationId,blockID,disposition:'reconciled',quoteSha256:current.quoteSha256,note:current.note};
  }
}

module.exports = {VaultBlockEdits};
