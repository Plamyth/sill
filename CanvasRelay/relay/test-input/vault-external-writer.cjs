'use strict';
const fs = require('node:fs');
const path = require('node:path');
const file = process.argv[2],bytes = Buffer.from(process.argv[3],'base64');
if (!path.resolve(file).split(path.sep).some(part => part.startsWith('vault-save-boundary-'))) process.exit(2);
if (process.argv[4] === 'atomic-replace') {
  const temporary = file+'.external';
  fs.writeFileSync(temporary,bytes,{flag:'wx'});fs.renameSync(temporary,file);
} else fs.writeFileSync(file,bytes);
