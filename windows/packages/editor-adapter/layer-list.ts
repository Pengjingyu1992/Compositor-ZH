import type { LayerRow } from '../../apps/desktop/renderer/types';

export function visibleLayers(rows: LayerRow[], query: string, collapsed: Set<string>): LayerRow[] {
  const id = (value?: string) => value?.toUpperCase() ?? '';
  const children = new Map<string, LayerRow[]>();
  const parents = new Map(rows.map(row => [id(row.id), id(row.parentID)]));
  for (const row of rows) {
    const parent = id(row.parentID);
    if (!children.has(parent)) children.set(parent, []);
    children.get(parent)!.push(row);
  }
  const search = query.trim().toLocaleLowerCase();
  const included = new Set<string>();
  if (search) {
    for (const row of rows) {
      if (!row.name.toLocaleLowerCase().includes(search)) continue;
      let key = id(row.id);
      while (key && !included.has(key)) { included.add(key); key = parents.get(key) ?? ''; }
    }
  }
  const result: LayerRow[] = [];
  function visit(parent: string, matchingAncestor = false) {
    for (const row of [...(children.get(parent) ?? [])].reverse()) {
      const key = id(row.id), matches = matchingAncestor || (!!search && row.name.toLocaleLowerCase().includes(search));
      if (search && !matches && !included.has(key)) continue;
      result.push(row);
      if (row.isGroup && (search || !collapsed.has(key))) visit(key, matches);
    }
  }
  visit('');
  return result;
}
