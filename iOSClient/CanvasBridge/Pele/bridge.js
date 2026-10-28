(() => {
  'use strict';
  const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
  const nodeID = /^n[0-9a-f]{32}$/;
  let current;
  const post = value => window.webkit?.messageHandlers?.canvasDiagram?.postMessage(value);
  const bytes = value => new TextEncoder().encode(value).length;
  const target = document.getElementById('diagram');
  const error = document.getElementById('error');
  function select(id) {
    const node = current?.nodes.find(node => node.diagramID === id || (node.kind === 'line' && 'x' + node.diagramID.slice(1) === id));
    if (!node || !uuid.test(node.id)) return false;
    post({ type:'select', sceneID:current.sceneID, revision:current.revision, nodeID:node.id });
    return true;
  }
  window.ccrDiagram = Object.freeze({
    select,
    update(payload) {
      const previous = current;
      current = undefined;
      error.textContent = '';
      try {
        if (!payload || !uuid.test(payload.sceneID) || !Number.isSafeInteger(payload.revision) || payload.revision < 0 ||
            typeof payload.source !== 'string' || bytes(payload.source) > 50000 ||
            !Array.isArray(payload.nodes) || payload.nodes.length > 512) throw Error('invalid snapshot');
        const ids = new Set(), uuids = new Set(), owners = new Map();
        for (const node of payload.nodes) {
          if (!nodeID.test(node.diagramID) || !uuid.test(node.id) || typeof node.text !== 'string' ||
              node.diagramID !== 'n' + node.id.toLowerCase().replaceAll('-','') ||
              ids.has(node.diagramID) || uuids.has(node.id.toLowerCase())) throw Error('invalid node identity');
          if (node.kind !== undefined && !['note','box','ellipse','line'].includes(node.kind)) throw Error('unknown node kind');
          ids.add(node.diagramID); uuids.add(node.id.toLowerCase()); owners.set(node.diagramID,node);
          if (node.kind === 'line') {
            const endpoint = 'x' + node.diagramID.slice(1);
            ids.add(endpoint); owners.set(endpoint,node);
          }
        }
        if (ids.size > 512 || (payload.displayedNodeCount !== undefined && payload.displayedNodeCount !== ids.size)) throw Error('node limit');
        if (payload.displayedEdgeCount !== undefined && (!Number.isSafeInteger(payload.displayedEdgeCount) ||
            payload.displayedEdgeCount < 0 || payload.displayedEdgeCount > 1024)) throw Error('edge limit');
        const lineOwner = element => payload.nodes.find(node => node.kind === 'line' &&
          element.dataset.id.startsWith('L_' + node.diagramID + '_x' + node.diagramID.slice(1) + '_'));
        const applySelection = svg => {
          for (const element of svg.querySelectorAll('.pele-node[data-id]')) {
            const node = owners.get(element.dataset.id);
            element.setAttribute('aria-selected',String(node.id === payload.selectedNodeID));
          }
          for (const element of svg.querySelectorAll('.pele-edge[data-id],.pele-edge-label[data-id]')) {
            const node = lineOwner(element);
            if (node) element.setAttribute('aria-selected',String(node.id === payload.selectedNodeID));
          }
        };
        if (previous && previous.source === payload.source &&
            JSON.stringify(previous.nodes) === JSON.stringify(payload.nodes) && target.querySelector('svg')) {
          const actualEdges = target.querySelectorAll('.pele-edge').length;
          if (actualEdges > 1024 || (payload.displayedEdgeCount !== undefined && payload.displayedEdgeCount !== actualEdges)) throw Error('edge count mismatch');
          applySelection(target);
          current = payload;
          return { nodes:ids.size, edges:target.querySelectorAll('.pele-edge').length, reused:true };
        }
        target.replaceChildren();
        if (!payload.nodes.length) {
          target.textContent = '구조 요소를 추가하면 관계가 표시됩니다. 자유그림의 자동 의미 해석은 지원하지 않습니다.';
          current = payload;
          return { nodes:0, edges:0 };
        }
        const model = pele.parse(payload.source, { limit:50000, maxEdges:1024 });
        if (model.edges.length > 1024 || (payload.displayedEdgeCount !== undefined && payload.displayedEdgeCount !== model.edges.length)) throw Error('edge limit');
        if (model.type !== 'flowchart' || !(model.nodes instanceof Map) || model.nodes.size !== ids.size ||
            [...model.nodes.keys()].some(id => !ids.has(id))) throw Error('unexpected graph');
        const result = pele.render(model, { links:false, images:false, limit:50000,
          maxEdges:1024, outputLimit:1000000, autoDirection:false, fontFamily:'-apple-system, sans-serif' });
        if (result.type !== 'flowchart') throw Error('unexpected diagram type');
        if (bytes(result.svg) > 1000000) throw Error('output limit');
        const parsed = new DOMParser().parseFromString(result.svg, 'image/svg+xml');
        const svg = parsed.documentElement;
        if (svg.localName !== 'svg' || parsed.querySelector('parsererror,script,foreignObject,image,a,iframe,style')) throw Error('unsafe SVG');
        for (const element of svg.querySelectorAll('*')) {
          for (const attribute of element.attributes) {
            if (/^on/i.test(attribute.name) || /href$/i.test(attribute.name)) throw Error('unsafe SVG attribute');
          }
        }
        if (svg.querySelectorAll('.pele-edge').length !== model.edges.length) throw Error('edge count mismatch');
        const rendered = [...svg.querySelectorAll('.pele-node[data-id]')];
        if (rendered.length !== ids.size || new Set(rendered.map(el => el.dataset.id)).size !== ids.size ||
            rendered.some(el => !ids.has(el.dataset.id))) throw Error('node identity mismatch');
        for (const element of rendered) {
          const node = owners.get(element.dataset.id);
          element.setAttribute('tabindex','0'); element.setAttribute('role','button');
          element.setAttribute('aria-label', node.text || '이름 없는 요소');
          element.setAttribute('aria-selected',String(node.id === payload.selectedNodeID));
          element.addEventListener('click', () => select(element.dataset.id));
          element.addEventListener('keydown', event => {
            if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); select(element.dataset.id); }
          });
        }
        for (const edge of svg.querySelectorAll('.pele-edge[data-id],.pele-edge-label[data-id]')) {
          const node = lineOwner(edge);
          if (!node) continue;
          edge.setAttribute('tabindex','0'); edge.setAttribute('role','button');
          edge.setAttribute('aria-label',node.text || '직선');
          edge.addEventListener('click',() => select(node.diagramID));
          edge.addEventListener('keydown',event => {
            if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); select(node.diagramID); }
          });
        }
        applySelection(svg);
        current = payload;
        target.append(document.adoptNode(svg));
        return { nodes:rendered.length, edges:svg.querySelectorAll('.pele-edge').length };
      } catch (_) {
        target.replaceChildren();
        error.textContent = '다이어그램을 표시하지 못했습니다. 원본 그림과 구조 데이터는 보존됩니다.';
        post({ type:'error' });
        return { error:true };
      }
    }
  });
})();
