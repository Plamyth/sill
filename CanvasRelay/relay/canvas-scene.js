'use strict';

const MAX_CANVAS_SCENE_BYTES = 4 * 1024 * 1024;
const SCENE_CAPABILITIES = Object.freeze({schema:'ccr.canvas-capabilities/v1',sceneSchemaVersions:[1,2,3],
  nodeKinds:['note','box','ellipse','line'],diagramProjection:'ccr.diagram-shapes/v1'});

const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const finiteFields = (value,fields) => record(value) && fields.every(key => Number.isFinite(value[key]));
const unit = value => Number.isFinite(value) && value >= 0 && value <= 1;

function validPenSettings(value) {
  return record(value) && Object.keys(value).every(key => ['version','color','width'].includes(key)) &&
    value.version === 1 && ['white','yellow','cyan'].includes(value.color) && [2,4,8].includes(value.width);
}

function assertInkScene(scene) {
  if (!record(scene) || !SCENE_CAPABILITIES.sceneSchemaVersions.includes(scene.schemaVersion) || !Array.isArray(scene.strokes))
    throw new Error('Invalid canvas scene');
  if (scene.penSettings != null && (scene.schemaVersion < 2 || !validPenSettings(scene.penSettings)))
    throw new Error('Invalid canvas pen settings');
  if (scene.schemaVersion >= 2 &&
      (!finiteFields(scene,['width','height']) || typeof scene.drawingBase64 !== 'string' ||
        !Array.isArray(scene.annotations))) throw new Error('Invalid canvas scene');
  assertSceneNodes(scene);
  for (const stroke of scene.strokes) {
    if (scene.schemaVersion >= 2 && (!record(stroke) || !Array.isArray(stroke.points) ||
        !stroke.points.every(point => finiteFields(point,['x','y','pressure']))))
      throw new Error('Invalid canvas stroke point');
    if (stroke?.style == null) continue;
    const style = stroke.style;
    if (scene.schemaVersion < 2 || !record(style) || style.version !== 1 ||
        typeof style.inkType !== 'string' || !style.inkType.length || !scene.drawingBase64.length ||
        (style.color != null && (!record(style.color) ||
          !['red','green','blue','alpha'].every(key => unit(style.color[key])))) ||
        !finiteFields(style.transform,['a','b','c','d','tx','ty']) ||
        !Array.isArray(style.samples) || style.samples.length !== stroke.points.length ||
        !style.samples.every(sample => finiteFields(sample,['width','height','opacity']) &&
          sample.width >= 0 && sample.height >= 0 && unit(sample.opacity)))
      throw new Error('Invalid canvas ink projection');
  }
}

function assertSceneNodes(scene) {
  if (!Array.isArray(scene.nodes)) throw new Error('그림 요소 목록이 올바르지 않습니다.');
  if (!SCENE_CAPABILITIES.sceneSchemaVersions.includes(scene.schemaVersion))
    throw new Error('지원하지 않는 그림 형식 버전입니다. 원본을 보존합니다.');
  const kinds = scene.schemaVersion === 3 ? SCENE_CAPABILITIES.nodeKinds : ['note','box'];
  for (const node of scene.nodes) {
    if (!record(node) || !kinds.includes(node.kind)) throw new Error('지원하지 않는 그림 요소 종류입니다. 원본을 보존합니다.');
    if (scene.schemaVersion === 3 &&
        (typeof node.id !== 'string' || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(node.id) ||
          typeof node.text !== 'string' || !finiteFields(node.frame,['x','y','width','height']) ||
          !Number.isFinite(node.frame.x + node.frame.width) || !Number.isFinite(node.frame.y + node.frame.height) ||
          (node.rotationDegrees != null && (!Number.isFinite(node.rotationDegrees) ||
            !Number.isFinite(node.rotationDegrees * Math.PI / 180)))))
      throw new Error('그림 요소의 기하 정보가 올바르지 않습니다.');
  }
}

function assertAgentRevision(scene, revision) {
  assertInkScene(scene);
  if (!Array.isArray(revision.proposedNodes)) throw new Error('그림 요소 제안 목록이 올바르지 않습니다.');
  const promote = revision.proposedNodes.some(node => ['ellipse','line'].includes(node?.kind));
  const version = promote ? 3 : scene.schemaVersion;
  assertSceneNodes({schemaVersion:version,nodes:revision.proposedNodes});
  if (revision.nodeEdits != null) {
    if (!Array.isArray(revision.nodeEdits)) throw new Error('그림 요소 수정 목록이 올바르지 않습니다.');
    assertSceneNodes({schemaVersion:scene.schemaVersion,nodes:revision.nodeEdits.map(edit => edit?.expected)});
  }
  assertInkScene({...scene,schemaVersion:version,nodes:[...scene.nodes,...revision.proposedNodes]});
  return version;
}

module.exports = {assertInkScene,assertSceneNodes,assertAgentRevision,SCENE_CAPABILITIES,MAX_CANVAS_SCENE_BYTES};
