import Foundation
import Testing
@testable import BezlCore
import BezlRing

@Suite struct EdgeGeometryTests {
    // 14" MacBook Pro default: 1512 x 982 pt, notch ~185 x 32 pt.
    let notched = EdgeGeometry.make(width: 1512, height: 982, safeAreaTop: 32,
                                    auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5)

    @Test func notchRectFromAuxiliaryAreas() throws {
        let n = try #require(notched.notch)
        #expect(n.x == 663.5)
        #expect(n.width == 185)
        #expect(n.height == 32)
        #expect(notched.topCornerRadius == EdgeGeometry.notchedTopCornerRadius)
        #expect(notched.bottomCornerRadius == 0)
    }

    @Test func externalDisplayHasNoNotch() {
        let g = EdgeGeometry.make(width: 2560, height: 1440, safeAreaTop: 0,
                                  auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil)
        #expect(g.notch == nil)
        #expect(g.topCornerRadius == 0)
    }

    @Test func cornerOverrideAppliesToAllCorners() {
        let g = EdgeGeometry.make(width: 2560, height: 1440, safeAreaTop: 0,
                                  auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, cornerRadiusOverride: 12)
        #expect(g.topCornerRadius == 12)
        #expect(g.bottomCornerRadius == 12)
    }

    @Test func distancesUseTopLeftOrigin() {
        // A point 5 pt below the top edge, far from the notch and corners.
        #expect(abs(notched.inwardDistance(x: 200, y: 5, followNotch: true) - 5) < 1e-9)
        // 7 pt from the left edge, mid-height.
        #expect(abs(notched.inwardDistance(x: 7, y: 491, followNotch: true) - 7) < 1e-9)
        // 3 pt above the bottom edge.
        #expect(abs(notched.inwardDistance(x: 756, y: 979, followNotch: true) - 3) < 1e-9)
    }

    @Test func notchIsAnEdgeOnlyWhenFollowing() {
        // 4 pt below the bottom of the notch, at its horizontal center.
        let x = 663.5 + 185 / 2, y = 32.0 + 4
        #expect(abs(notched.inwardDistance(x: x, y: y, followNotch: true) - 4) < 1e-9)
        #expect(abs(notched.inwardDistance(x: x, y: y, followNotch: false) - 36) < 1e-9)
        // Inside the notch is "outside" the lit shape.
        #expect(notched.inwardDistance(x: x, y: 10, followNotch: true) < 0)
    }

    @Test func roundedCornerPushesPointsOutside() {
        // The very top-left pixel is outside a 10 pt rounded corner.
        #expect(notched.inwardDistance(x: 0.5, y: 0.5, followNotch: true) < 0)
        // ...but inside a square-cornered display.
        let square = EdgeGeometry.make(width: 100, height: 100, safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil)
        #expect(square.inwardDistance(x: 0.5, y: 0.5, followNotch: true) > 0)
    }
}

@Suite struct SettingsTests {
    @Test func roundTrip() throws {
        var s = BezlSettings()
        s.look.thickness = 12
        s.look.colorSource = .manual
        s.look.motion = .breathe
        s.displays["ABC"] = DisplaySettings(enabled: false, followNotch: false, cornerRadius: 4)
        let data = try #require(s.encoded())
        #expect(BezlSettings.decode(data) == s)
    }

    @Test func missingKeysUseDefaults() throws {
        let data = Data(#"{"look":{"thickness":20}}"#.utf8)
        let s = try #require(BezlSettings.decode(data))
        #expect(s.look.thickness == 20)
        #expect(s.look.glow == LookSettings().glow)
        #expect(s.isActive)
        #expect(s.musicSync)
    }

    @Test func unknownEnumFallsBack() throws {
        let data = Data(#"{"look":{"motion":"disco","colorSource":"screen"}}"#.utf8)
        let s = try #require(BezlSettings.decode(data))
        #expect(s.look.motion == .beat)
        #expect(s.look.colorSource == .albumArt)
    }

    @Test func sanitizeClamps() {
        var l = LookSettings()
        l.thickness = 500
        l.glow = -1
        l.primaryWeight = 1
        let s = l.sanitized
        #expect(s.thickness == 40)
        #expect(s.glow == 0)
        #expect(s.primaryWeight == 0.9)
    }

    @Test func presetExportImport() throws {
        let p = Preset.builtIns[0]
        let imported = try Preset.importing(try p.exportData())
        #expect(imported.name == p.name)
        #expect(imported.look == p.look)
        #expect(imported.id != p.id)
        #expect(!imported.isBuiltIn)
    }

    @Test func builtInPresetsHaveStableUniqueIDs() {
        #expect(Set(Preset.builtIns.map(\.id)).count == Preset.builtIns.count)
    }
}

@Suite struct RingBufferTests {
    @Test func writeReadOrder() throws {
        let ring = try #require(bezl_ring_create(8))
        defer { bezl_ring_destroy(ring) }
        let input: [Float] = [1, 2, 3, 4, 5]
        #expect(bezl_ring_write(ring, input, 5) == 5)
        var out = [Float](repeating: 0, count: 5)
        #expect(bezl_ring_read(ring, &out, 5) == 5)
        #expect(out == input)
        #expect(bezl_ring_available(ring) == 0)
    }

    @Test func dropsWhenFullAndWraps() throws {
        let ring = try #require(bezl_ring_create(4))
        defer { bezl_ring_destroy(ring) }
        #expect(bezl_ring_write(ring, [1, 2, 3, 4, 5, 6], 6) == 4)
        var out = [Float](repeating: 0, count: 2)
        #expect(bezl_ring_read(ring, &out, 2) == 2)
        #expect(out == [1, 2])
        #expect(bezl_ring_write(ring, [7, 8], 2) == 2)
        var rest = [Float](repeating: 0, count: 4)
        #expect(bezl_ring_read(ring, &rest, 4) == 4)
        #expect(rest == [3, 4, 7, 8])
    }

    @Test func concurrentProducerConsumer() async throws {
        let ring = try #require(bezl_ring_create(1024))
        defer { bezl_ring_destroy(ring) }
        nonisolated(unsafe) let r = ring
        let total = 200_000
        let producer = Task.detached {
            var next: Float = 0
            var chunk = [Float](repeating: 0, count: 64)
            while next < Float(total) {
                for i in 0..<64 { chunk[i] = next + Float(i) }
                let n = min(64, total - Int(next))
                let written = bezl_ring_write(r, chunk, n)
                next += Float(written)
                if written == 0 { await Task.yield() }
            }
        }
        var expected: Float = 0
        var buf = [Float](repeating: 0, count: 100)
        var ok = true
        while Int(expected) < total {
            let n = bezl_ring_read(r, &buf, 100)
            for i in 0..<n where buf[i] != expected + Float(i) { ok = false }
            expected += Float(n)
            if n == 0 { await Task.yield() }
        }
        await producer.value
        #expect(ok)
    }
}
