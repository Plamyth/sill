'use strict';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const AUTHOR = '카드 태그';
function markdown(input) {
  if (typeof input !== 'string') return null;
  const name = input.startsWith('#') ? input.slice(1) : input;
  if (!name || Buffer.byteLength(name) > 128 ||
      !/^[A-Za-z0-9_\-\u1100-\u11ff\u3130-\u318f\uac00-\ud7a3]+$/u.test(name) || /^[0-9]+$/.test(name)) return null;
  return '#' + name;
}
const key = tag => tag.normalize('NFC').toLowerCase();
const uuidKey = value => typeof value === 'string' && UUID.test(value) ? value.toLowerCase() : null;
function rows(scene) {
  const notes = Array.isArray(scene.nodes) ? scene.nodes : [];
  const annotations = Array.isArray(scene.annotations) ? scene.annotations : [];
  const nodeIDs = notes.map(x => uuidKey(x?.id)), annotationIDs = annotations.map(x => uuidKey(x?.id));
  if (nodeIDs.includes(null) || annotationIDs.includes(null) ||
      new Set(nodeIDs).size !== notes.length || new Set(annotationIDs).size !== annotations.length) return [];
  const groups = new Map();
  for (const annotation of annotations) {
    if (annotation.author !== AUTHOR) continue;
    const id = uuidKey(annotation.nodeId);
    if (!groups.has(id)) groups.set(id, []);
    groups.get(id).push(annotation);
  }
  const result = [];
  for (const note of notes) {
    if (note.kind !== 'note') continue;
    const records = groups.get(uuidKey(note.id)) || [];
    const tags = records.map(x => markdown(x.text));
    if (!records.length || records.some((x, i) => !UUID.test(x.id) || !tags[i] || tags[i] !== x.text) ||
        new Set(tags.map(key)).size !== tags.length) continue;
    result.push({ nodeID: note.id, tags });
  }
  return result;
}
module.exports = { markdown, key, rows };
