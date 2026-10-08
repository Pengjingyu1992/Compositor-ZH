import AppKit
import Metal

/// Optional sampler for the same immutable source and displacement grid as the CPU path.
/// Limit full-source GPU copies to 16 MP; larger layers use the bounded CPU renderer.
nonisolated final class LiquifyMetalRenderer: @unchecked Sendable {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let source: MTLTexture
    private let coverage: MTLBuffer
    private let hasCoverage: Bool
    init?(source bytes: Data, coverage mask: Data?, width: Int, height: Int) {
        guard width * height <= 16_777_216, let device = MTLCreateSystemDefaultDevice(),
            let queue = device.makeCommandQueue(),
            let library = try? device.makeLibrary(source: Self.shader, options: Self.options()),
            let function = library.makeFunction(name: "liquify_sample"),
            let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        bytes.withUnsafeBytes {
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!,
                bytesPerRow: width * 4)
        }
        let coverage: MTLBuffer?
        if let mask {
            coverage = mask.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: mask.count, options: .storageModeShared)
            }
        } else {
            coverage = device.makeBuffer(length: 1, options: .storageModeShared)
        }
        guard let coverage else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.source = texture
        self.coverage = coverage
        hasCoverage = mask != nil
    }
    private static func options() -> MTLCompileOptions {
        let options = MTLCompileOptions()
        options.mathMode = .safe
        return options
    }
    func render(nodes: Data, gridWidth: Int, gridHeight: Int, step: Int, width: Int, height: Int, keepsAlpha: Bool)
        -> CGImage?
    {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderWrite
        guard let out = device.makeTexture(descriptor: descriptor),
            let field = nodes.withUnsafeBytes({
                device.makeBuffer(bytes: $0.baseAddress!, length: nodes.count, options: .storageModeShared)
            }),
            let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder(),
            let context = try? BrushRaster.context(width: width, height: height, mask: false), let pixels = context.data
        else { return nil }
        let parameters: [Int32] = [
            Int32(source.width), Int32(source.height), Int32(width), Int32(height), Int32(gridWidth), Int32(gridHeight),
            Int32(step), hasCoverage ? 1 : 0, keepsAlpha ? 1 : 0,
        ]
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(out, index: 1)
        encoder.setBuffer(field, offset: 0, index: 0)
        encoder.setBuffer(coverage, offset: 0, index: 1)
        parameters.withUnsafeBufferPointer { encoder.setBytes($0.baseAddress!, length: parameters.count * 4, index: 2) }
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        out.getBytes(
            pixels, bytesPerRow: context.bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return context.makeImage()
    }
    private static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct Node { float dx; float dy; float frozen; };
        kernel void liquify_sample(texture2d<float, access::read> src [[texture(0)]],
            texture2d<float, access::write> out [[texture(1)]],device const Node *n [[buffer(0)]],
            device const uchar *mask [[buffer(1)]],constant int *p [[buffer(2)]],uint2 xy [[thread_position_in_grid]]) {
            int w=p[0],h=p[1],ow=p[2],oh=p[3],gw=p[4],gh=p[5];
            if(xy.x>=uint(ow)||xy.y>=uint(oh))return;
            float2 pos=(float2(xy)+.5f)*float2(w,h)/float2(ow,oh)-.5f;
            float2 grid=clamp(pos/float(p[6]),float2(0),float2(gw-1,gh-1));
            int2 a=int2(grid),b=min(a+1,int2(gw-1,gh-1));float2 f=grid-float2(a);
            Node aa=n[a.y*gw+a.x],ab=n[a.y*gw+b.x],ba=n[b.y*gw+a.x],bb=n[b.y*gw+b.x];
            float2 d=mix(mix(float2(aa.dx,aa.dy),float2(ab.dx,ab.dy),f.x),mix(float2(ba.dx,ba.dy),float2(bb.dx,bb.dy),f.x),f.y);
            float2 at=clamp(pos+d,float2(0),float2(w-1,h-1));int2 i=int2(at),j=min(i+1,int2(w-1,h-1));float2 t=at-float2(i);
            float4 top=mix(round(src.read(uint2(i))*255.f),round(src.read(uint2(j.x,i.y))*255.f),t.x);
            float4 bottom=mix(round(src.read(uint2(i.x,j.y))*255.f),round(src.read(uint2(j))*255.f),t.x);
            int2 original=clamp(int2(round(pos)),int2(0),int2(w-1,h-1));
            float4 base=round(src.read(uint2(original))*255.f);
            float selected=p[7] ? float(mask[original.y*w+original.x])/255.f : 1.f;
            float4 result=clamp(round(mix(base,mix(top,bottom,t.y),selected)),float4(0),float4(255));
            if(p[8]) { result.rgb=min(float3(base.a),result.a>0 ? floor((result.rgb*base.a+floor(result.a/2))/result.a):base.rgb);result.a=base.a; }
            out.write(result/255.f,xy);
        }
        """
}
