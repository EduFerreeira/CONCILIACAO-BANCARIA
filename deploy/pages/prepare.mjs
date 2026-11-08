import {mkdir,copyFile,writeFile} from 'node:fs/promises';import path from 'node:path';import {fileURLToPath}from'node:url';
const here=path.dirname(fileURLToPath(import.meta.url)),root=path.resolve(here,'../..'),output=path.join(here,'dist');
await mkdir(path.join(output,'static'),{recursive:true});
await copyFile(path.join(root,'online/static/portal.html'),path.join(output,'index.html'));
for(const name of ['portal.js','portal.css','finance-bootstrap.js','finance-bridge.js'])await copyFile(path.join(root,'online/static',name),path.join(output,'static',name));
await copyFile(path.join(root,'conciliacao-bancaria.html'),path.join(output,'finance-base.html'));
await copyFile(path.join(root,'deploy/cloudflare/worker.mjs'),path.join(output,'_worker.js'));
await writeFile(path.join(output,'_routes.json'),JSON.stringify({version:1,include:['/*'],exclude:[]},null,2));
console.log('Cloudflare Pages: conciliacao-bancaria-ebt • Supabase configurado por URL pública. Nenhuma publicação foi feita.');
