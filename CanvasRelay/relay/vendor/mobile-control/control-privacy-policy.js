'use strict';
const fs=require('node:fs');
const path=require('node:path');
function watchPrivacyPolicy({file,onInvalidate,onError,watch=fs.watch,stat=fs.lstatSync}){
  if(!file)return ()=>{};
  let watcher,closed=false;
  function close(){if(closed)return;closed=true;watcher?.close();}
  function fail(error){if(closed)return;close();onError(error);}
  function check(){if(!stat(file).isFile())throw Error('hidden_policy_unavailable');}
  try{
    const basename=path.basename(file);
    watcher=watch(path.dirname(file),(_,filename)=>{
      if(closed)return;
      const name=Buffer.isBuffer(filename)?filename.toString('utf8'):filename;
      if(name!=null&&name!==basename)return;
      try{check();onInvalidate();}catch(error){fail(error);}
    });
    watcher.on('error',fail);
    watcher.on('close',()=>{if(!closed)fail(Error('hidden_policy_watch_closed'));});
    check();
  }catch(error){fail(error);}
  return close;
}
module.exports={watchPrivacyPolicy};
