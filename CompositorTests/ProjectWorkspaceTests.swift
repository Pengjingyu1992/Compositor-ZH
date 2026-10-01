import AppKit
import UniformTypeIdentifiers
import Testing
@testable import Compositor

@MainActor struct ProjectWorkspaceTests {
    @Test func newCanvasOpensAnEmptyTabWithoutAModal() {
        let workspace = ProjectWorkspace()
        let original = workspace.current
        original.session.createDocument(width: 4000, height: 3000)
        workspace.newCanvas()
        #expect(workspace.tabs.count == 2)
        #expect(workspace.current !== original)
        #expect(workspace.current.session.document == nil)
        #expect(!workspace.current.session.showsNewDocument)
        #expect(workspace.canSwitch)
        #expect(original.session.document?.size.width == 4000)
        workspace.newCanvas()
        #expect(workspace.tabs.count == 3)
        #expect(!workspace.current.session.showsNewDocument)
    }

    /// A gradient waiting for Apply used to leave Quit and the close button doing nothing at all; quitting applies it.
    @Test func quittingAppliesAPendingGradient() async throws {
        let workspace = ProjectWorkspace()
        let session = workspace.current.session
        session.createDocument(width: 100, height: 20)
        session.addBlankLayer()
        session.selectTool(.gradient)
        session.beginGradient(at: CGPoint(x: 0, y: 10))
        session.moveGradient(end: CGPoint(x: 100, y: 10))
        session.endGradientDrag()
        #expect(!workspace.canSwitch)
        let count = session.history.undoCount
        await workspace.settlePendingEdits()
        #expect(session.gradientEdit == nil)
        #expect(session.history.undoCount == count + 1)
        #expect(workspace.canSwitch)
    }

    /// An open dialog used to block Quit too; quitting cancels it, leaving the layer as it was.
    @Test func quittingCancelsAnOpenDialog() async throws {
        let workspace = ProjectWorkspace()
        let session = workspace.current.session
        session.createDocument(width: 100, height: 20)
        session.insert(try LiveMaskTests().asset([200, 100, 50, 255]))
        let original = session.activeLayer?.asset?.image
        for open in [{ session.beginFilter(.gaussianBlur) }, { session.beginHueSaturation() }, { session.beginLevels() }] {
            open()
            #expect(!workspace.canSwitch)
            await workspace.settlePendingEdits()
            #expect(workspace.canSwitch)
            #expect(session.activeLayer?.asset?.image === original)
        }
    }

    @Test func layerDropProviderCopiesIntoANewProject() async throws {
        let workspace = ProjectWorkspace()
        let source = workspace.current
        source.session.createDocument(width: 100, height: 100)
        source.session.insert(try LiveMaskTests().asset([255,255,255,255]))
        let id = try #require(source.session.activeLayerID)
        let provider = NSItemProvider(item: Data(id.uuidString.utf8) as NSData, typeIdentifier: ProjectWorkspace.layerType)
        await workspace.receiveProviders([provider])
        #expect(workspace.tabs.count == 2)
        #expect(workspace.current.id != source.id)
        #expect(workspace.current.session.document?.layers.count == 1)
        #expect(workspace.current.session.activeLayerID != id)
        #expect(source.session.document?.layers.first?.id == id)
    }

    @Test func tabsKeepIndependentDocumentsAndUndo() throws {
        let workspace = ProjectWorkspace()
        let first = workspace.current
        first.session.createDocument(width: 4000, height: 4000)
        first.session.addBlankLayer()
        let second = workspace.addTab()
        second.session.createDocument(width: 640, height: 480)
        second.session.addBlankLayer()
        second.session.undo()
        #expect(first.session.document?.layers.count == 1)
        #expect(second.session.document?.layers.isEmpty == true)
        workspace.select(first.id)
        #expect(workspace.current === first)
        #expect(first.session.document?.size.width == 4000)
        workspace.removeTab(second.id)
        #expect(workspace.current === first)
        workspace.removeTab(first.id)
        #expect(workspace.tabs.count == 1 && workspace.current.session.document == nil)
    }

    @Test func crossProjectCopyRemapsIdentityAndHasIndependentUndo() async throws {
        let workspace = ProjectWorkspace()
        let first = workspace.current
        first.session.createDocument(width: 100, height: 100)
        first.session.insert(try LiveMaskTests().asset([255,255,255,255]))
        let original = try #require(first.session.activeLayerID)
        let second = workspace.addTab()
        second.session.createDocument(width: 200, height: 200)
        await workspace.copyLayer(original, into: second.id)
        let copied = try #require(second.session.document?.layers.first)
        #expect(copied.id != original)
        #expect(copied.transform.center == CGPoint(x: 100, y: 100))
        #expect(first.session.document?.layers.count == 1)
        second.session.undo()
        #expect(second.session.document?.layers.isEmpty == true)
        #expect(first.session.document?.layers.count == 1)
        second.session.redo()
        #expect(second.session.document?.layers.first?.id == copied.id)
    }

    @Test func dockCreatesTabsAndTargetedImportUsesExistingTab() async throws {
        let url = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let workspace = ProjectWorkspace()
        await workspace.receive([url, url])
        #expect(workspace.tabs.count == 2)
        let first = workspace.tabs[0]
        await workspace.receive([url], into: first.id)
        #expect(workspace.tabs.count == 2)
        #expect(workspace.current === first)
        #expect(first.session.document?.layers.count == 2)
        #expect(workspace.tabs[1].session.document?.layers.count == 1)
    }

    @Test func moveTabReordersWithoutTouchingSelectionOrDocuments() {
        let workspace = ProjectWorkspace()
        let a = workspace.current
        let b = workspace.addTab(reuseEmpty: false)
        let c = workspace.addTab(reuseEmpty: false)
        #expect(workspace.tabs.map(\.id) == [a.id, b.id, c.id])
        workspace.moveTab(c.id, to: 0)
        #expect(workspace.tabs.map(\.id) == [c.id, a.id, b.id])
        workspace.moveTab(a.id, to: 2)
        #expect(workspace.tabs.map(\.id) == [c.id, b.id, a.id])
        // An out-of-range target clamps to the array's bounds instead of crashing.
        workspace.moveTab(c.id, to: 99)
        #expect(workspace.tabs.map(\.id) == [b.id, a.id, c.id])
        // Moving to where a tab already is, or moving an id that isn't a tab, does nothing.
        let unchanged = workspace.tabs.map(\.id)
        workspace.moveTab(c.id, to: 2)
        workspace.moveTab(UUID(), to: 0)
        #expect(workspace.tabs.map(\.id) == unchanged)
        #expect(workspace.current === c) // reordering is chrome — it never moves the selection
    }

    /// Quit asks about the project on screen first, then the others left to right.
    @Test @MainActor func quitAsksAboutTheActiveTabFirst() {
        let workspace = ProjectWorkspace()
        let first = workspace.current
        let second = workspace.addTab(reuseEmpty: false)
        let third = workspace.addTab(reuseEmpty: false)
        workspace.select(second.id)
        #expect(workspace.quitOrder.map(\.id) == [second.id, first.id, third.id])
        workspace.select(third.id)
        #expect(workspace.quitOrder.map(\.id) == [third.id, first.id, second.id])
        workspace.select(first.id)
        #expect(workspace.quitOrder.map(\.id) == [first.id, second.id, third.id])
    }
}
