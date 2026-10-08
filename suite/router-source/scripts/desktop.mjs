import {Store} from '../server/store.mjs';
const [directory,port='5147']=process.argv.slice(2);
if(!directory)throw new Error('Provide the managed data directory.');
const store=new Store(directory);
console.log(`http://127.0.0.1:${Number(port)}/#token=${store.secrets.adminToken}`);
