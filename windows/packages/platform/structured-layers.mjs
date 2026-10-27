import sharp from './native-imaging.mjs';
import { ProjectError } from '../comp-bridge/project.mjs';
import { checkPermission } from '../comp-bridge/editor-ops.mjs';
import { vectorSVG, mapVectorPath } from '../comp-bridge/layer-styles.mjs';

export async function prepareStructuredOperation(data, operation) {
  if(!['path','vectorMask'].includes(operation.kind))return operation;
  checkPermission(data,operation);
  const op=structuredClone(operation),target=data.manifest.layers.find(layer=>layer.id===op.id);
  if(op.id&&!target)throw new ProjectError('stale');
  const resource=target&&data.resources.get(`images/${op.kind==='vectorMask'?(target.maskFile??target.imageFile):target.imageFile}`);
  const width=resource?.width??op.width??data.manifest.width,height=resource?.height??op.height??data.manifest.height;
  if(op.kind==='vectorMask'&&op.sourcePathID){
    const source=data.manifest.layers.find(layer=>layer.id===op.sourcePathID);
    if(!source?.shape?.vector||!target)throw new ProjectError('invalid');
    op.style=mapVectorPath(source.shape.vector,source.transform,target.maskPlacement??target.transform);
  }
  const color=op.color??{red:0,green:0,blue:0};
  const svg=vectorSVG(width,height,op.style,color,op.kind==='vectorMask');
  op.png=await sharp(Buffer.from(svg),{limitInputPixels:16_000_000}).png().timeout({seconds:20}).toBuffer();
  return op;
}
