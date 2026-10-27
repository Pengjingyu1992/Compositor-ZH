// Only remove assets previously owned by known layer records. Unrecognized
// files remain opaque resources, preserving the bridge's forward compatibility.
export function pruneOwnedResources(before,after,resources) {
  const images=manifest=>new Set(manifest.layers.flatMap(layer=>[layer.imageFile,layer.maskFile].filter(Boolean)).map(name=>`images/${name}`));
  const current=images(after);
  for(const key of images(before))if(!current.has(key))resources.delete(key);
  const edits=manifest=>new Set(manifest.layers.flatMap(layer=>layer.editableFilters?[layer.editableFilters.sourceFile,...(layer.editableFilters.nodeFiles??[])]:[]).filter(name=>typeof name==='string'&&/^[a-f0-9-]{36}(?:\.source\.png|\.[a-f0-9-]{36}\.filter\.json)$/i.test(name)).map(name=>`edits/${name}`));
  const retained=edits(after);for(const key of edits(before))if(!retained.has(key))resources.delete(key);
}
