import CoreGraphics
import Testing
@testable import Compositor

struct ScanlinesTests {
    /// One column of a Scanlines render of a flat gray, as brightness per row.
    private func scanlines(gray: CGFloat, spacing: Double, glow: Double = 0) throws -> [Int] {
        let context = try BrushRaster.context(width: 16, height: 32, mask: false)
        context.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 32))
        var settings = ScanlinesSettings()
        settings.lineSpacing = spacing
        settings.glow = glow
        let result = try BrushRaster.copy(try settings.apply(try #require(context.makeImage())))
        let data = try #require(result.data).assumingMemoryBound(to: UInt8.self)
        return (0..<32).map { Int(data[$0 * result.bytesPerRow + 5 * 4]) }
    }

    /// Scanlines is a CRT: lines of light on a dark screen, every Line Spacing pixels, thicker and brighter where the
    /// picture is light.
    @Test func scanlinesAreLinesOfLightThatBloomWithBrightness() throws {
        let white = try scanlines(gray: 1, spacing: 8), gray = try scanlines(gray: 0.35, spacing: 8)
        let black = try scanlines(gray: 0, spacing: 8)
        for band in 0..<4 {
            let rows = Array(white[band * 8..<band * 8 + 8])
            #expect(rows[3] == 255 && rows[4] == 255, "a white line is lit through its middle: \(rows)")
            #expect(rows.contains { $0 < 40 }, "with dark screen between lines: \(rows)")
        }
        #expect(gray.reduce(0, +) * 2 < white.reduce(0, +), "a gray line is thinner and dimmer than a white one")
        #expect(black.allSatisfy { $0 == 0 })
    }

    private func render(_ image: CGImage, _ adjust: (inout ScanlinesSettings) -> Void) throws -> (data: UnsafeMutablePointer<UInt8>, row: Int, context: CGContext) {
        var settings = ScanlinesSettings()
        settings.glow = 0
        adjust(&settings)
        let result = try BrushRaster.copy(try settings.apply(image))
        return (try #require(result.data).assumingMemoryBound(to: UInt8.self), result.bytesPerRow, result)
    }

    private func flat(_ width: Int, _ height: Int, _ fill: (CGContext) -> Void) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        fill(context)
        return try #require(context.makeImage())
    }

    /// On solid white, glow lights the gaps without filling them up to the lines; on solid black, Black Level lights them.
    @Test func linesShowOnSolidWhiteAndBlack() throws {
        let white = try scanlines(gray: 1, spacing: 8, glow: 100)
        #expect(white.max()! - white.min()! > 40, "lines and gaps on white with full glow: \(white)")
        let context = try BrushRaster.context(width: 16, height: 32, mask: false)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 32))
        var settings = ScanlinesSettings()
        settings.lineSpacing = 8
        settings.blackLevel = 40
        let result = try BrushRaster.copy(try settings.apply(try #require(context.makeImage())))
        let data = try #require(result.data).assumingMemoryBound(to: UInt8.self)
        let column = (0..<8).map { Int(data[$0 * result.bytesPerRow + 8 * 4]) }
        #expect(column.max()! > 60 && column.min()! < 10, "lines and gaps on black: \(column)")
    }

    /// Glow lights the dark screen between the lines.
    @Test func glowLightsBetweenTheLines() throws {
        let plain = try scanlines(gray: 1, spacing: 8), glowing = try scanlines(gray: 1, spacing: 8, glow: 100)
        #expect(glowing[0] > plain[0] + 40, "between the lines: \(plain[0]) without glow, \(glowing[0]) with")
    }

    /// Dots break the lines into beads where the picture is darker than the Dots level: along a gray line's middle, dark
    /// gaps come every line spacing, while a white line above the level stays solid.
    @Test func dotsBeadTheLinesBelowTheirLevel() throws {
        func filled(_ gray: CGFloat) throws -> CGImage {
            try flat(64, 16) { $0.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)); $0.fill(CGRect(x: 0, y: 0, width: 64, height: 16)) }
        }
        let middle = { (r: (data: UnsafeMutablePointer<UInt8>, row: Int, context: CGContext)) in (0..<64).map { Int(r.data[4 * r.row + $0 * 4]) } }
        let white = middle(try render(try filled(1)) { $0.lineSpacing = 8; $0.dots = 70 })
        #expect(white.allSatisfy { $0 == 255 }, "white stays a solid line: \(white)")
        let gray = middle(try render(try filled(0.4)) { $0.lineSpacing = 8; $0.dots = 70 })
        #expect(gray[3] > 100 && gray[4] > 100 && gray[0] < 40 && gray[8] < 40, "beads every 8 pixels: \(gray)")
    }

    /// Wobble pushes lines sideways by different amounts: a vertical edge no longer lines up from line to line.
    @Test func wobbleMovesLinesSideways() throws {
        let edge = try flat(64, 64) { $0.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); $0.fill(CGRect(x: 32, y: 0, width: 32, height: 64)) }
        func edges(_ wobble: Double) throws -> Set<Int> {
            let r = try render(edge) { $0.lineSpacing = 8; $0.wobble = wobble }
            return Set((0..<8).map { line in (0..<64).first { r.data[(line * 8 + 4) * r.row + $0 * 4] > 128 } ?? -1 })
        }
        #expect(try edges(0) == [32])
        #expect(try edges(12).count >= 3)
    }

    /// Displace lifts a line where the picture is bright: over a white half, the line's middle sits higher than over the
    /// black half, where it stays put.
    @Test func displaceLiftsLinesWhereThePictureIsBright() throws {
        let half = try flat(64, 64) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 32, y: 0, width: 32, height: 64))
        }
        let r = try render(half) { settings in
            settings.lineSpacing = 16
            settings.displace = 6
            settings.colors = .original
        }
        func brightest(column x: Int) -> Int {
            var best = 0, row = 0
            for y in 16..<32 {
                let value = Int(r.data[y * r.row + x * 4])
                if value > best { best = value; row = y }
            }
            return row
        }
        #expect(brightest(column: 48) < 24, "the line over white rises above the line's own middle")
    }

    /// Displace: a line lifted over a bright band hides the line behind it, which still shows where nothing is in front.
    @Test func aLiftedLineHidesTheLinesBehindIt() throws {
        let band = try flat(64, 80) { context in
            context.setFillColor(CGColor(srgbRed: 0.25, green: 0.25, blue: 0.25, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 80))
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            // The third line's rows, 32–48, in the middle columns; centered, so either way up.
            context.fill(CGRect(x: 16, y: 32, width: 32, height: 16))
        }
        let r = try render(band) { settings in
            settings.lineSpacing = 16
            settings.displace = 40
            settings.smoothness = 0
        }
        // Over the gray the second line rises 10, to row 14; the third, over white, rises 40 to the top, in front of it.
        #expect(r.data[14 * r.row + 4 * 4] > 20, "the second line shows where nothing is in front of it")
        #expect(r.data[14 * r.row + 32 * 4] < 8, "the lifted line hides it")
        #expect(r.data[2 * r.row + 32 * 4] > 200, "the lifted line is drawn")
    }

    /// Threshold leaves the screen dark where the picture is darker than it.
    @Test func thresholdDarkensWhatsBelowIt() throws {
        let gray = try flat(32, 32) { context in
            context.setFillColor(CGColor(srgbRed: 0.3, green: 0.3, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let shown = try render(gray) { $0.lineSpacing = 8 }
        let hidden = try render(gray) { settings in
            settings.lineSpacing = 8
            settings.threshold = 60
        }
        let litBefore = (0..<32).contains { y in shown.data[y * shown.row + 16 * 4] > 40 }
        let litAfter = (0..<32).contains { y in hidden.data[y * hidden.row + 16 * 4] > 10 }
        #expect(litBefore && !litAfter)
    }
}
