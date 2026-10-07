import AppKit
import Testing
@testable import Compositor

@MainActor
struct ColorRangeSelectionTests {
    private func fixture() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 64, height: 64)
        let context = try BrushRaster.context(width: 64, height: 64, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 32, y: 0, width: 32, height: 64))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Color range fixture"))
        return session
    }

    private func waitForResult(_ edit: ColorRangeEdit) async throws {
        for _ in 0..<200 where edit.isComputing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!edit.isComputing)
    }

    @Test func immediateConfirmWaitsForLatestSampleAndUndoesOnce() async throws {
        let session = try fixture()
        session.beginColorRange()
        let edit = try #require(session.colorRange)
        let count = session.history.undoCount
        session.sampleColorRange(at: CGPoint(x: 5, y: 5), shift: false, option: false)
        session.sampleColorRange(at: CGPoint(x: 50, y: 5), shift: false, option: false)
        session.commitColorRange()
        #expect(edit.commitRequested && session.colorRange === edit)
        try await waitForResult(edit)
        let selection = try #require(session.selection)
        #expect(session.colorRange == nil)
        #expect(selection.path.contains(CGPoint(x: 50, y: 5)))
        #expect(!selection.path.contains(CGPoint(x: 5, y: 5)))
        #expect(session.history.undoCount == count + 1)
        session.undo()
        #expect(session.selection == nil)
        session.redo()
        #expect(session.selection == selection)
    }

    @Test func cancelAfterConfirmRequestIgnoresLateResult() async throws {
        let session = try fixture()
        session.selectAll()
        let original = session.selection, count = session.history.undoCount
        session.beginColorRange()
        session.sampleColorRange(at: CGPoint(x: 5, y: 5), shift: false, option: false)
        session.commitColorRange()
        session.cancelColorRange()
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.colorRange == nil && session.selection == original)
        #expect(session.history.undoCount == count)
    }

    @Test func pendingConfirmCannotModifyReplacementDocument() async throws {
        let session = try fixture(), replacement = try fixture()
        replacement.selectAll()
        let document = try #require(replacement.document)
        session.beginColorRange()
        session.sampleColorRange(at: CGPoint(x: 5, y: 5), shift: false, option: false)
        session.commitColorRange()
        session.document = document
        try await Task.sleep(for: .milliseconds(300))
        session.commitColorRange()
        session.cancelColorRange()
        #expect(session.document == document)
    }

    @Test func changedFuzzinessIsIncludedInPendingConfirmation() async throws {
        let session = try fixture()
        session.beginColorRange()
        let edit = try #require(session.colorRange)
        session.sampleColorRange(at: CGPoint(x: 5, y: 5), shift: false, option: false)
        edit.fuzziness = 200
        session.updateColorRange()
        session.commitColorRange()
        try await waitForResult(edit)
        #expect(session.colorRange == nil && session.selection != nil)
    }
}
