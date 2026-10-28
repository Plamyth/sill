'use strict';
const path = require('node:path');
const {root,projectControl} = require('./vendor/mobile-control/mobile-control');

function installedReadOnlyRows(snapshot, hidden, clock) {
  return require(path.join(root(),'unified-control.js')).rows(snapshot,null,clock,hidden);
}

function controlRoomSources(snapshot, hidden, clock = Date.now(), rows = installedReadOnlyRows) {
  return projectControl(snapshot,{hidden,workspace:'all',rows:(value,ids) => rows(value,ids,clock)});
}

module.exports = {controlRoomSources};
