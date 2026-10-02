import { readProject } from '../packages/comp-bridge/project.mjs';
import { editProject } from '../packages/comp-bridge/edit.mjs';
import { saveProject, fingerprint } from '../packages/platform/save-project.mjs';
const [location,registry,phase]=process.argv.slice(2);
const before=await readProject(location),after=editProject(before,{kind:'rename',id:before.manifest.layers[0].id,name:'Saved before crash'});
await saveProject(after,location,fingerprint(before),registry,{[phase]:()=>process.exit(23)});
