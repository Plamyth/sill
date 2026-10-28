'use strict';

const {SCENE_CAPABILITIES} = require('./canvas-scene');
const UUID = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const key = value => typeof value === 'string' && UUID.test(value) ? value.toLowerCase() : null;

function canvasMermaid(scene) {
  const nodes = scene.nodes, links = scene.links;
  if (!Array.isArray(nodes) || !Array.isArray(links) || nodes.length > 512 || links.length > 1024) return null;
  if (scene.schemaVersion != null && !SCENE_CAPABILITIES.sceneSchemaVersions.includes(scene.schemaVersion) ||
      nodes.some(node => node?.kind != null && !SCENE_CAPABILITIES.nodeKinds.includes(node.kind)) ||
      scene.schemaVersion !== 3 && nodes.some(node => ['ellipse','line'].includes(node?.kind))) return null;
  const ids = new Set(nodes.map(node => key(node?.id))), edgeIds = new Set(links.map(link => key(link?.id)));
  if (ids.has(null) || ids.size !== nodes.length || edgeIds.has(null) || edgeIds.size !== links.length ||
      nodes.some(node => typeof node.text !== 'string') ||
      links.some(link => !ids.has(key(link.from)) || !ids.has(key(link.to)) || typeof link.label !== 'string')) return null;

  const validHierarchy = hierarchy => {
    const parents = new Map();
    for (const link of hierarchy) {
      const from = key(link.from), to = key(link.to);
      if (from === to || !ids.has(from) || !ids.has(to) || parents.has(to)) return false;
      parents.set(to,from);
    }
    for (const node of parents.keys()) {
      const path = new Set(); let current = node;
      while (parents.has(current)) {
        if (path.has(current)) return false;
        path.add(current); current = parents.get(current);
      }
    }
    return true;
  };
  let hierarchy = links.filter(link => link.kind === 'parentChild');
  if (!validHierarchy(hierarchy)) {
    const ordered = hierarchy.slice().sort((a,b) => {
      const lhs = [a.id,a.from,a.to].map(key).join(':'), rhs = [b.id,b.from,b.to].map(key).join(':');
      return lhs < rhs ? -1 : lhs > rhs ? 1 : 0;
    });
    hierarchy = [];
    for (const link of ordered) if (validHierarchy([...hierarchy,link])) hierarchy.push(link);
  }
  const children = new Map();
  for (const link of hierarchy) {
    const from = key(link.from);
    if (!children.has(from)) children.set(from,[]);
    children.get(from).push(key(link.to));
  }
  const hidden = new Set(), pending = nodes.filter(node => node.isCollapsed === true)
    .flatMap(node => children.get(key(node.id)) || []);
  while (pending.length) {
    const id = pending.pop();
    if (hidden.has(id)) continue;
    hidden.add(id); pending.push(...(children.get(id) || []));
  }
  const diagramID = id => 'n' + key(id).replaceAll('-','');
  const label = text => Array.from(text, char => {
    const code = char.codePointAt(0);
    return code < 128 && !/[a-zA-Z0-9 ]/.test(char) ? `#${code};` : char;
  }).join('');
  const lines = ['flowchart TD'];
  const visible = nodes.filter(node => !hidden.has(key(node.id)));
  const visibleLinks = links.filter(link => !hidden.has(key(link.from)) && !hidden.has(key(link.to)));
  const primitiveCount = visible.filter(node => node.kind === 'line').length;
  if (visible.length + primitiveCount > 512 || visibleLinks.length + primitiveCount > 1024) return null;
  for (const node of visible) {
    const id = diagramID(node.id);
    if (node.kind === 'line') {
      const endpoint = 'x' + id.slice(1);
      lines.push(`${id}[" "]`,`${endpoint}[" "]`,
        `${id} ---|"${label(node.text || '직선')}"| ${endpoint}`,
        `class ${id},${endpoint} ccrLineEndpoint`);
    } else {
      lines.push(`${id}["${label(node.text || '이름 없는 요소')}"]`);
      if (node.kind === 'ellipse') lines.push(`class ${id} ccrEllipse`);
    }
  }
  if (visible.some(node => node.kind === 'ellipse')) lines.push('classDef ccrEllipse rx:50%,ry:50%');
  if (visible.some(node => node.kind === 'line')) lines.push('classDef ccrLineEndpoint fill:none,stroke:none');
  for (const link of visibleLinks) {
    const relation = link.label || (link.kind === 'parentChild' ? '하위 요소' : '연결');
    lines.push(`${diagramID(link.from)} -->|"${label(relation)}"| ${diagramID(link.to)}`);
  }
  const source = lines.join('\n');
  return Buffer.byteLength(source,'utf8') <= 50_000 ? source : null;
}

function canvasDiagramMarkdown(scene) {
  if (!Array.isArray(scene.nodes) || !scene.nodes.length) return '';
  const source = canvasMermaid(scene);
  if (source === null) return '\n## 다이어그램\n\n표시 한도나 구조를 확인하세요. 원본 그림과 구조 데이터는 보존됩니다.\n';
  const mode = scene.nodes.some(node => ['ellipse','line'].includes(node?.kind)) ?
    '<!-- ccr.diagram-shapes/v1 -->\n자동 배치 모드입니다. 원본의 위치·크기·회전은 위 기하 정보와 JSON을 확인하세요.\n\n' : '';
  return '\n## 다이어그램\n\n' + mode + '<!-- ccr:mermaid:v1 -->\n```mermaid\n' + source + '\n```\n';
}

module.exports = {canvasMermaid,canvasDiagramMarkdown};
