'use strict';

const MAX_CANVAS_SCENE_BYTES = 4 * 1024 * 1024;

const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const finiteFields = (value,fields) => record(value) && fields.every(key => Number.isFinite(value[key]));
const unit = value => Number.isFinite(value) && value >= 0 && value <= 1;

function validPenSettings(value) {
  return record(value) && Object.keys(value).every(key => ['version','color','width'].includes(key)) &&
    value.version === 1 && ['white','yellow','cyan'].includes(value.color) && [2,4,8].includes(value.width);
}

function assertInkScene(scene) {
  if (!record(scene) || ![1,2].includes(scene.schemaVersion) || !Array.isArray(scene.strokes))
    throw new Error('Invalid canvas scene');
  if (scene.penSettings != null && (scene.schemaVersion !== 2 || !validPenSettings(scene.penSettings)))
    throw new Error('Invalid canvas pen settings');
  if (scene.schemaVersion === 2 &&
      (!finiteFields(scene,['width','height']) || typeof scene.drawingBase64 !== 'string' ||
        !Array.isArray(scene.annotations))) throw new Error('Invalid canvas scene');
  for (const stroke of scene.strokes) {
    if (scene.schemaVersion === 2 && (!record(stroke) || !Array.isArray(stroke.points) ||
        !stroke.points.every(point => finiteFields(point,['x','y','pressure']))))
      throw new Error('Invalid canvas stroke point');
    if (stroke?.style == null) continue;
    const style = stroke.style;
    if (scene.schemaVersion !== 2 || !record(style) || style.version !== 1 ||
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

module.exports = {assertInkScene,MAX_CANVAS_SCENE_BYTES};
