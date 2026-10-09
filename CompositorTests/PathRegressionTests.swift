import AppKit
#if !PATH_CLT_CHECKS
import Testing
@testable import Compositor
#endif

@MainActor struct PathRegressionChecks {
    struct Result { var checks = 0; var failures: [String] = [] }
    static func run(output: URL) async throws -> Result {
        var result = Result()
        func check(_ label: String, _ value: Bool) { result.checks += 1; if !value { result.failures.append(label); print("FAIL: \(label)") } }
        let outer = VectorContour(anchors:[PathAnchor(point:CGPoint(x:0.1,y:0.1)),PathAnchor(point:CGPoint(x:0.9,y:0.1)),
            PathAnchor(point:CGPoint(x:0.9,y:0.9)),PathAnchor(point:CGPoint(x:0.1,y:0.9))],closed:true)
        let inner = VectorContour(anchors:[PathAnchor(point:CGPoint(x:0.3,y:0.3)),PathAnchor(point:CGPoint(x:0.7,y:0.3)),
            PathAnchor(point:CGPoint(x:0.7,y:0.7)),PathAnchor(point:CGPoint(x:0.3,y:0.7))],closed:true)
        var vector = VectorPathStyle(contours:[outer,inner],evenOdd:true,strokeEnabled:true,strokeColor:.black,strokeWidth:2)
        check("path validation",vector.isValid)
        let encoded = try JSONEncoder().encode(vector), decoded = try JSONDecoder().decode(VectorPathStyle.self,from:encoded)
        check("anchor/handle JSON roundtrip",decoded == vector)
        var invalid = vector; invalid.contours[0].anchors[0].point.x = .nan
        check("nonfinite anchor refused",!invalid.isValid)
        invalid = vector; invalid.strokeWidth = .infinity; check("nonfinite stroke refused",!invalid.isValid)
        invalid = vector; invalid.contours[0].anchors[0].outgoing = CGPoint(x:1001,y:0)
        check("oversized handle refused",!invalid.isValid)
        let image = try EditorSession.shapeImage(.path,size:CGSize(width:100,height:100),color:.white,vector:vector)
        let pixels = try BrushRaster.copy(image), data = pixels.data!.assumingMemoryBound(to:UInt8.self)
        check("even-odd hole transparent",data[50*pixels.bytesPerRow+50*4+3] == 0)
        check("path filled inside",data[20*pixels.bytesPerRow+20*4+3] == 255)
        let style = LayerShapeStyle(kind:.path,red:1,green:1,blue:1,cornerRadius:0,vector:vector)
        let session = EditorSession(); session.createDocument(width:480,height:320)
        session.addPixelLayer(image,at:CGPoint(x:30,y:30),name:"Vector",editName:"New Path",shape:LayerShape(style:style,image:image))
        let original = session.document, layerID = session.activeLayerID!
        session.selectTool(.pen); session.beginPathEditing()
        check("path draft blocks other edits",!session.canEditLayers && !session.canStartProjectOperation)
        session.pathEditing?.style.contours[0].anchors[0].outgoing = CGPoint(x:0.6,y:0)
        session.pathEditing = nil; check("cancel has no document mutation",session.document == original)
        session.beginPathEditing(); session.pathEditing?.style.contours[0].anchors[0].outgoing = CGPoint(x:0.6,y:0)
        session.finishPathEditing(); check("path applied",session.activeLayer?.liveShape?.style.vector != vector)
        session.undo(); check("path undo",session.document == original)
        session.redo(); check("path redo",session.activeLayer?.liveShape?.style.vector != vector)
        session.beginPathEditing()
        let oldTransform = session.pathEditing!.transform
        session.pathEditing?.style.contours[0].anchors[0].point = CGPoint(x:1.5,y:0.2)
        let outside = CGPoint(x:1.5,y:0.2).applying(BrushRaster.pixelToDocument(oldTransform,width:1,height:1))
        session.finishPathEditing()
        let expandedLayer = session.activeLayer!
        let expandedPoint = expandedLayer.liveShape!.style.vector!.contours[0].anchors[0].point
            .applying(BrushRaster.pixelToDocument(expandedLayer.transform,width:1,height:1))
        check("path editing expands raster bounds",expandedLayer.size.width > oldTransform.size.width)
        check("expanded path preserves document position",hypot(expandedPoint.x-outside.x,expandedPoint.y-outside.y) < 0.001)
        session.undo()
        session.beginPathEditing(); session.document = CanvasDocument(width:20,height:20)
        session.finishPathEditing(); check("stale path refuses new document",session.document?.layers.isEmpty == true && session.pathEditing == nil)
        session.document = original; session.selectLayer(layerID); session.history.reset()
        session.toggleSelectedLayerLock(.content); session.beginPathEditing()
        check("content lock does not open existing path",session.pathEditing == nil)
        session.pathEditing = nil; session.toggleSelectedLayerLock(.content)
        session.beginPathEditing(new:true)
        session.pathMouseDown(CGPoint(x:120,y:60),option:false,double:false)
        session.dragPath(to:CGPoint(x:150,y:60),option:false); session.pathEditing?.dragPart = nil
        check("pen symmetric handles",session.pathEditing?.style.contours[0].anchors[0].incoming != nil)
        session.pathMouseDown(CGPoint(x:200,y:100),option:false,double:false); session.pathEditing?.dragPart = nil
        session.pathMouseDown(CGPoint(x:120,y:160),option:false,double:false); session.pathEditing?.dragPart = nil
        session.pathMouseDown(CGPoint(x:120,y:60),option:false,double:false)
        check("pen click first closes",session.pathEditing?.style.contours[0].closed == true)
        session.finishPathEditing(); check("new pen path committed",session.activeLayer?.liveShape?.style.vector != nil)
        session.makeVectorMask()
        check("vector mask created on lower layer",session.activeLayer?.mask?.vector != nil)
        let maskDoc = session.document
        session.beginVectorMaskEditing()
        check("vector mask editable draft",session.pathEditing?.mask == true)
        session.pathEditing?.style.evenOdd.toggle(); session.finishPathEditing()
        check("vector mask applied",session.activeLayer?.mask?.vector?.evenOdd != maskDoc?.layers.first?.mask?.vector?.evenOdd)
        session.undo(); check("vector mask undo",session.document == maskDoc)
        session.redo()
        let saved = session.projectSnapshot()!
        try await ProjectStore.shared.validateSnapshot(saved)
        let folder = output.appendingPathComponent("paths-v13.comp")
        try await ProjectStore.shared.save(saved,to:folder)
        let loaded = try await ProjectStore.shared.load(from:folder)
        check("v13 path persisted",loaded.manifest.version == 13 && loaded.manifest.layers.map { $0.shape?.vector } == saved.manifest.layers.map { $0.shape?.vector } && loaded.manifest.layers.map { $0.vectorMask } == saved.manifest.layers.map { $0.vectorMask })
        var old = saved.manifest; old.version = 12
        do { try await ProjectStore.shared.validateSnapshot(ProjectSnapshot(manifest:old,images:saved.images)); check("v12 refuses path metadata",false) }
        catch { check("v12 refuses path metadata",true) }
        var text = LayerTextStyle(); text.content = "叠绘 ABC"; text.fontName = "Helvetica"; text.fontSize = 32; text.boxSize = CGSize(width:360,height:140)
        text.colorRuns = [LayerTextColorRun(location:3,length:3,red:1,green:0,blue:0)]
        let outlines = try PathTypography.outlines(text)
        check("CJK and Latin outline",outlines.isValid && outlines.contours.count > 6)
        check("outline colors retained",outlines.contours.contains { $0.color?.red == 1 && $0.color?.green == 0 })
        let textImage = try EditorSession.textImage(text)
        let outlinedImage = try EditorSession.shapeImage(.path,size:CGSize(width:textImage.width,height:textImage.height),color:.black,vector:outlines)
        let nativePixels = try BrushRaster.copy(textImage), outlinePixels = try BrushRaster.copy(outlinedImage)
        let nativeBytes = nativePixels.data!.assumingMemoryBound(to:UInt8.self), outlineBytes = outlinePixels.data!.assumingMemoryBound(to:UInt8.self)
        var alphaDifference = 0
        for y in 0..<textImage.height { for x in 0..<textImage.width {
            alphaDifference += abs(Int(nativeBytes[y*nativePixels.bytesPerRow+x*4+3])-Int(outlineBytes[y*outlinePixels.bytesPerRow+x*4+3]))
        } }
        check("outline matches native layout",Double(alphaDifference)/Double(textImage.width*textImage.height) < 2)
        var vertical = text; vertical.vertical = true
        let verticalOutline = try PathTypography.outlines(vertical)
        check("vertical outline rendered",verticalOutline.isValid)

        session.addPixelLayer(textImage,at:.zero,name:"Type",editName:"New Text Layer",text:LayerText(style:text,image:textImage))
        let commandDoc = session.document!
        let command = await session.executePosterBatch(PosterBatchRequest(documentID:commandDoc.id,expectedRevision:session.history.currentRevision,
            commands:[PosterCommand(kind:.addPath,vector:vector,transform:LayerTransform(origin:.zero,size:CGSize(width:100,height:100)),color:FillColor(red:1,green:0,blue:0))]))
        check("path batch succeeds",command.status == "changed")
        session.undo(); check("path batch one undo",session.document == commandDoc)
        let beforeOutline = session.document; session.convertTextToOutlines()
        check("convert removes text and stores path",session.activeLayer?.liveText == nil && session.activeLayer?.liveShape?.style.vector != nil)
        session.undo(); check("outline conversion undo",session.document == beforeOutline)
        text.pathLayout = TextPathLayout(path:VectorPathStyle(contours:[VectorContour(anchors:[
            PathAnchor(point:CGPoint(x:0.05,y:0.6),outgoing:CGPoint(x:0.3,y:0.1)),
            PathAnchor(point:CGPoint(x:0.95,y:0.6),incoming:CGPoint(x:0.7,y:0.1))])]))
        let pathText = try EditorSession.textImage(text)
        check("text on curve rendered",pathText.width == 360 && pathText.height == 140)
        text.pathLayout?.reversed = true; check("reverse text path rendered",try EditorSession.textImage(text).width == 360)
        text.pathLayout?.offset = 5000
        do { _ = try EditorSession.textImage(text); check("overflow text explicitly refused",false) }
        catch { check("overflow text explicitly refused",true) }
        text.pathLayout = nil; text.warp = TextWarp(bend:0.25)
        check("arc warp rendered",try EditorSession.textImage(text).width == 360)
        let transformed = LayerTransform(origin:CGPoint(x:12,y:18),size:CGSize(width:100,height:100),rotation:30,flipX:true)
        let psdVector = try PSDEditableWriter.vector(vector,transform:transformed,canvas:CGSize(width:480,height:320))
        let readPath = PSDVector.model(from:psdVector,canvas:CGSize(width:480,height:320))!
        check("PSD subpaths and fill rule",readPath.contours.count == 2 && readPath.evenOdd)
        let first = readPath.contours[0].anchors[0].point
        let expected = outer.anchors[0].point.applying(BrushRaster.pixelToDocument(transformed,width:1,height:1))
        check("PSD rotated/flipped anchor",abs(first.x*480-expected.x) < 0.001 && abs(first.y*320-expected.y) < 0.001)
        var paddedVector = psdVector
        paddedVector.append(Data(repeating:0,count:(4-paddedVector.count%4)%4))
        check("PSD padded vector accepted",PSDVector.model(from:paddedVector,canvas:CGSize(width:480,height:320)) == readPath)
        paddedVector.append(1)
        check("PSD invalid vector trailing bytes refused",PSDVector.model(from:paddedVector,canvas:CGSize(width:480,height:320)) == nil)
        let boundaryPath = VectorPathStyle(contours:[VectorContour(anchors:[
            PathAnchor(point:CGPoint(x:CGFloat(128).nextDown,y:0)), PathAnchor(point:.zero)])])
        do {
            _ = try PSDEditableWriter.vector(boundaryPath,transform:LayerTransform(origin:.zero,size:CGSize(width:1,height:1)),canvas:CGSize(width:1,height:1))
            check("PSD rounded fixed-point overflow refused",false)
        } catch { check("PSD rounded fixed-point overflow refused",true) }
        vector.contours = [outer]; vector.evenOdd = false
        let psdSession = EditorSession(); psdSession.createDocument(width:480,height:320)
        let fill = LayerFillStyle(kind:.linear)
        let fillImage = try fill.render(width:480,height:320)
        psdSession.addPixelLayer(fillImage,at:.zero,name:"Gradient",editName:"New Fill Layer",fill:LayerFill(style:fill,image:fillImage))
        let shapeImage = try EditorSession.shapeImage(.path,size:CGSize(width:100,height:100),color:.white,vector:vector)
        psdSession.addPixelLayer(shapeImage,at:CGPoint(x:30,y:30),name:"Bezier",editName:"New Path",
            shape:LayerShape(style:LayerShapeStyle(kind:.path,red:1,green:1,blue:1,cornerRadius:0,vector:vector),image:shapeImage))
        text.warp = nil
        psdSession.addPixelLayer(textImage,at:CGPoint(x:20,y:150),name:"Editable Chinese",editName:"New Text Layer",text:LayerText(style:text,image:textImage))
        psdSession.document?.layers[2].effects = LayerEffects(shadow:ShadowEffect(distance:4,blur:3),colorOverlay:ColorOverlayEffect(red:0.9,green:0.2,blue:0.5,opacity:0.2))
        psdSession.addAdjustment(.curves)
        let snapshot = psdSession.projectSnapshot()!
        check("mapped PSD does not require flattening",!PSDWriter.requiresFlattening(snapshot))
        try await ProjectStore.shared.save(snapshot,to:output.appendingPathComponent("editable.comp"),quickLook:ImageExporter.shared.quickLookImages(snapshot))
        let raster = try await ImageExporter.shared.render(snapshot)
        let psd = try PSDWriter.encode(snapshot,composite:raster.image,mode:.layered)
        try psd.write(to:output.appendingPathComponent("editable.psd"))
        try await ImageExporter.shared.exportPNG(snapshot,to:output.appendingPathComponent("editable.png"))
        let parsed = try PSDReader.read(psd)
        check("PSD layer count",parsed.layers.count == snapshot.manifest.layers.count)
        check("PSD text retained",parsed.layers.contains { $0.text?.style.content == text.content })
        check("PSD CJK fallback font explicit",parsed.layers.first { $0.text != nil }?.text?.style.fontName(at:0) != "Helvetica")
        check("PSD color runs retained",parsed.layers.first { $0.text != nil }?.text?.style.colorRuns?.count == 1)
        check("PSD Bezier retained",parsed.layers.first { $0.name == "Bezier" }?.shape?.vector != nil)
        check("PSD gradient retained",parsed.layers.first { $0.name == "Gradient" }?.fill?.stops.count == 2)
        check("PSD effects retained",parsed.layers.first { $0.name == "Editable Chinese" }?.effects?.shadow != nil)
        check("PSD curves retained",parsed.layers.contains { $0.adjustment?.kind == .curves })
        let imported = try PSDDocumentBuilder.makeImport(parsed)
        check("PSD import live path",imported.layers.contains { $0.liveShape?.style.vector != nil })
        check("PSD import live fill",imported.layers.contains { $0.liveFill != nil })
        return result
    }
}

#if !PATH_CLT_CHECKS
struct PathRegressionTests {
    @Test @MainActor func editablePathsAndPSD() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PathChecks-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let result = try await PathRegressionChecks.run(output:folder)
        #expect(result.failures.isEmpty,"\(result.failures)")
    }
}
#endif
