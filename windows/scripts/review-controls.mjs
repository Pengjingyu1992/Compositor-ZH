import { readFile, readdir, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse as parseComponent } from '@vue/compiler-sfc';
import { parse as parseTemplate } from '@vue/compiler-dom';
import { commandCatalog } from '../apps/desktop/renderer/command-catalog.ts';

const root = fileURLToPath(new URL('../', import.meta.url));
const directory = path.join(root, 'apps/desktop/renderer');
const buttons = [], formComponents = new Set(), components = [];
for (const name of (await readdir(directory)).filter(name => name.endsWith('.vue')).sort()) {
  const { descriptor, errors } = parseComponent(await readFile(path.join(directory, name), 'utf8'));
  if (errors.length) throw new Error(`Cannot parse ${name}`);
  const template = descriptor.template;
  if (!template) continue;
  const visit = (node, inForm = false) => {
    if (node.type === 1) {
      const attributes = Object.fromEntries(node.props.map(prop => [
        prop.type === 6 ? prop.name : prop.name + (prop.arg ? ':' + prop.arg.content : ''),
        prop.type === 6 ? prop.value?.content : prop.exp?.content
      ]));
      if (node.tag === 'button') buttons.push({ component:name, line:template.loc.start.line + node.loc.start.line - 1, inForm, attributes });
      if (/^[A-Z]/.test(node.tag)) {
        components.push({ parent:name, child:node.tag + '.vue', inForm });
        if (inForm) formComponents.add(node.tag + '.vue');
      }
      inForm ||= node.tag === 'form';
    }
    for (const child of node.children ?? []) visit(child, inForm);
  };
  visit(parseTemplate(template.content));
}
// A child component's buttons inherit the surrounding form's submit behavior.
for (let pass = 0; pass < components.length; pass++) for (const edge of components) {
  if (formComponents.has(edge.parent)) formComponents.add(edge.child);
}
const implicitSubmits = buttons.filter(button => (button.inForm || formComponents.has(button.component)) && !button.attributes.type);
if (implicitSubmits.length) throw new Error('Unintended form submit buttons: ' + implicitSubmits.map(button => button.component + ':' + button.line).join(', '));
if (new Set(commandCatalog.map(command => command[0])).size !== commandCatalog.length) throw new Error('Duplicate command identifier');
const inventory = {
  schema:1,
  counting:'Static button declarations; v-for instances and parameter combinations are not separate declarations. Functional coverage is reported by scenario, not inferred from this count.',
  buttonDeclarations:buttons.length,
  commandCount:commandCatalog.length,
  implicitFormSubmits:implicitSubmits.length,
  components:Object.fromEntries([...new Set(buttons.map(button => button.component))].map(name => [name, buttons.filter(button => button.component === name).length])),
  commands:commandCatalog.map(([id,zh,en,shortcut]) => ({ id, zh, en, shortcut })),
  buttons
};
const output = path.join(root, 'test-results/control-inventory.json');
await mkdir(path.dirname(output), { recursive:true });
await writeFile(output, JSON.stringify(inventory, null, 2) + '\n');
console.log(`Control inventory: ${buttons.length} button declarations; ${commandCatalog.length} commands; no implicit form submits. Inventory is not an execution-coverage percentage.`);
