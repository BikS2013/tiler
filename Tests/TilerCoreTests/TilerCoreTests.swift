import XCTest
@testable import TilerCore

final class BSPTreeTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)

    func testSingleWindowFillsTheArea() {
        let t = BSPTree()
        t.insert(1, splitting: nil)
        XCTAssertEqual(t.layout(in: screen, gap: 10)[1], screen)
    }

    func testDwindleSplitsTheLongerSideOfTheTarget() {
        let t = BSPTree()
        t.insert(1, splitting: nil)
        _ = t.layout(in: screen, gap: 0)
        t.insert(2, splitting: 1)
        var f = t.layout(in: screen, gap: 0)
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 500, height: 600))
        XCTAssertEqual(f[2], CGRect(x: 500, y: 0, width: 500, height: 600))
        // Window 2 is taller than wide now: splitting it stacks vertically.
        t.insert(3, splitting: 2)
        f = t.layout(in: screen, gap: 0)
        XCTAssertEqual(f[2], CGRect(x: 500, y: 0, width: 500, height: 300))
        XCTAssertEqual(f[3], CGRect(x: 500, y: 300, width: 500, height: 300))
    }

    func testGapSeparatesTiles() {
        let t = BSPTree()
        t.insert(1, splitting: nil); _ = t.layout(in: screen, gap: 10)
        t.insert(2, splitting: 1)
        let f = t.layout(in: screen, gap: 10)
        XCTAssertEqual(f[1]!.maxX + 10, f[2]!.minX)
    }

    func testRemovePromotesSibling() {
        let t = BSPTree()
        t.insert(1, splitting: nil); _ = t.layout(in: screen, gap: 0)
        t.insert(2, splitting: 1); _ = t.layout(in: screen, gap: 0)
        t.insert(3, splitting: 2); _ = t.layout(in: screen, gap: 0)
        t.remove(2)
        let f = t.layout(in: screen, gap: 0)
        XCTAssertEqual(f[3], CGRect(x: 500, y: 0, width: 500, height: 600))
        XCTAssertEqual(t.windows, [1, 3])
        t.remove(1); t.remove(3)
        XCTAssertTrue(t.isEmpty)
    }

    func testInsertWithoutTargetSplitsLastLeaf() {
        let t = BSPTree()
        t.insert(1, splitting: nil); _ = t.layout(in: screen, gap: 0)
        t.insert(2, splitting: 99); _ = t.layout(in: screen, gap: 0)
        XCTAssertEqual(t.windows, [1, 2])
    }

    func testSwapExchangesPositions() {
        let t = BSPTree()
        t.insert(1, splitting: nil); _ = t.layout(in: screen, gap: 0)
        t.insert(2, splitting: 1)
        t.swap(1, 2)
        let f = t.layout(in: screen, gap: 0)
        XCTAssertEqual(f[2]!.minX, 0)
        XCTAssertEqual(t.windows, [2, 1])
        t.remove(1)
        XCTAssertEqual(t.windows, [2])
    }

    func testMoveDividerPrefersTheSideOfTheArrow() {
        let t = BSPTree()
        t.insert(1, splitting: nil); _ = t.layout(in: screen, gap: 0)
        t.insert(2, splitting: 1)
        XCTAssertTrue(t.moveDivider(of: 1, .right, step: 0.1))
        XCTAssertEqual(t.layout(in: screen, gap: 0)[1]!.width, 600)
        // Window 2 has no divider on its right: its left divider moves right.
        XCTAssertTrue(t.moveDivider(of: 2, .right, step: 0.1))
        XCTAssertEqual(t.layout(in: screen, gap: 0)[1]!.width, 700)
        XCTAssertFalse(t.moveDivider(of: 2, .up, step: 0.1))
    }

    func testRatioIsClamped() {
        let t = BSPTree()
        t.insert(1, splitting: nil); _ = t.layout(in: screen, gap: 0)
        t.insert(2, splitting: 1)
        for _ in 0..<20 { t.moveDivider(of: 1, .right, step: 0.1) }
        XCTAssertEqual(t.layout(in: screen, gap: 0)[1]!.width, 900)
    }

    func testMirrorKeepsWidths() {
        let t = BSPTree()
        t.insert(1, splitting: nil); _ = t.layout(in: screen, gap: 0)
        t.insert(2, splitting: 1)
        t.moveDivider(of: 1, .right, step: 0.2)
        t.mirrorHorizontally()
        let f = t.layout(in: screen, gap: 0)
        XCTAssertEqual(f[1], CGRect(x: 300, y: 0, width: 700, height: 600))
        XCTAssertEqual(f[2], CGRect(x: 0, y: 0, width: 300, height: 600))
    }

    func testToggleOrientationAndEqualize() {
        let t = BSPTree()
        t.insert(1, splitting: nil); _ = t.layout(in: screen, gap: 0)
        t.insert(2, splitting: 1)
        t.moveDivider(of: 1, .right, step: 0.2)
        t.toggleOrientation(of: 2)
        t.equalize()
        let f = t.layout(in: screen, gap: 0)
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 1000, height: 300))
    }

    func testAdoptResizeFollowsTheDraggedEdge() {
        let t = BSPTree()
        t.insert(1, splitting: nil); _ = t.layout(in: screen, gap: 10)
        t.insert(2, splitting: 1)
        let before = t.layout(in: screen, gap: 10)
        var dragged = before[1]!
        dragged.size.width += 100
        XCTAssertTrue(t.adoptResize(of: 1, to: dragged, gap: 10))
        let after = t.layout(in: screen, gap: 10)
        XCTAssertEqual(after[1]!.maxX, dragged.maxX, accuracy: 1)
        XCTAssertEqual(after[2]!.minX, dragged.maxX + 10, accuracy: 1)
        // A pure move changes nothing.
        XCTAssertFalse(t.adoptResize(of: 1, to: after[1]!, gap: 10))
    }
}

final class GeometryTests: XCTestCase {
    func testNeighborPrefersOverlappingTiles() {
        let frames: [WindowID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 500, height: 600),
            2: CGRect(x: 500, y: 0, width: 500, height: 300),
            3: CGRect(x: 500, y: 300, width: 500, height: 300),
        ]
        XCTAssertEqual(Geometry.neighbor(of: 3, .left, in: frames), 1)
        XCTAssertEqual(Geometry.neighbor(of: 3, .up, in: frames), 2)
        XCTAssertNil(Geometry.neighbor(of: 3, .down, in: frames))
        XCTAssertNil(Geometry.neighbor(of: 1, .left, in: frames))
        XCTAssertEqual(Geometry.neighbor(of: 1, .right, in: frames), 2) // tie on gap; closer centre wins → both equal, lower id
    }

    func testWindowAtPoint() {
        let frames: [WindowID: CGRect] = [1: CGRect(x: 0, y: 0, width: 10, height: 10)]
        XCTAssertEqual(Geometry.window(at: CGPoint(x: 5, y: 5), in: frames), 1)
        XCTAssertNil(Geometry.window(at: CGPoint(x: 50, y: 5), in: frames))
    }
}

final class ConfigTests: XCTestCase {
    func testTemplateParses() throws {
        let c = try Config.parse(Data(Config.template.utf8))
        XCTAssertEqual(c.innerGap, 8)
        XCTAssertEqual(c.hotkeys.count, Action.allCases.count)
        XCTAssertEqual(c.hotkeys[.focusLeft], try KeyCombo.parse("cmd+ctrl+left"))
    }

    func testMissingKeyIsAnError() {
        var dict = try! JSONSerialization.jsonObject(with: Data(Config.template.utf8)) as! [String: Any]
        dict.removeValue(forKey: "outerGap")
        let data = try! JSONSerialization.data(withJSONObject: dict)
        XCTAssertThrowsError(try Config.parse(data)) { XCTAssertEqual($0 as? ConfigError, .missingKey("outerGap")) }
    }

    func testMissingHotkeyIsAnErrorButNoneUnbinds() throws {
        var dict = try JSONSerialization.jsonObject(with: Data(Config.template.utf8)) as! [String: Any]
        var keys = dict["hotkeys"] as! [String: String]
        keys["mirror"] = "none"
        dict["hotkeys"] = keys
        let c = try Config.parse(try JSONSerialization.data(withJSONObject: dict))
        XCTAssertNil(c.hotkeys[.mirror])
        keys.removeValue(forKey: "mirror")
        dict["hotkeys"] = keys
        XCTAssertThrowsError(try Config.parse(try JSONSerialization.data(withJSONObject: dict)))
    }

    func testBadHotkeysAreRejected() {
        XCTAssertThrowsError(try KeyCombo.parse("left"))
        XCTAssertThrowsError(try KeyCombo.parse("hyper+left"))
        XCTAssertThrowsError(try KeyCombo.parse("ctrl+banana"))
    }

    func testDuplicateHotkeyIsRejected() throws {
        var dict = try JSONSerialization.jsonObject(with: Data(Config.template.utf8)) as! [String: Any]
        var keys = dict["hotkeys"] as! [String: String]
        keys["mirror"] = "ctrl+cmd+left"
        dict["hotkeys"] = keys
        XCTAssertThrowsError(try Config.parse(try JSONSerialization.data(withJSONObject: dict)))
    }

    func testUnknownKeyIsRejected() throws {
        var dict = try JSONSerialization.jsonObject(with: Data(Config.template.utf8)) as! [String: Any]
        dict["gapz"] = 3
        XCTAssertThrowsError(try Config.parse(try JSONSerialization.data(withJSONObject: dict)))
    }

    func testJSONRoundTrips() throws {
        var dict = try JSONSerialization.jsonObject(with: Data(Config.template.utf8)) as! [String: Any]
        var keys = dict["hotkeys"] as! [String: String]
        keys["mirror"] = "none"
        keys["retile"] = "cmd+alt+\\"
        dict["hotkeys"] = keys
        dict["innerGap"] = 4.5
        let c = try Config.parse(try JSONSerialization.data(withJSONObject: dict))
        let again = try Config.parse(Data(c.json().utf8))
        XCTAssertEqual(again, c)
        XCTAssertEqual(Config.defaults, try Config.parse(Data(Config.defaults.json().utf8)))
    }

    func testComboFromKeyEvent() throws {
        let combo = try XCTUnwrap(KeyCombo(keyCode: 0x7B, carbonModifiers: KeyCombo.cmdKey | KeyCombo.controlKey))
        XCTAssertEqual(combo.canonicalText, "ctrl+cmd+left")
        XCTAssertEqual(combo.symbols, "⌃⌘←")
        XCTAssertEqual(combo, try KeyCombo.parse("cmd+ctrl+left"))
        XCTAssertNil(KeyCombo(keyCode: 0x7B, carbonModifiers: 0))
        XCTAssertNil(KeyCombo(keyCode: 0xFF, carbonModifiers: KeyCombo.cmdKey))
    }

    func testConflicts() {
        let c = Config.defaults
        XCTAssertEqual(c.conflicts(c.hotkeys[.retile]!, for: .equalize), [.retile])
        XCTAssertEqual(c.conflicts(c.hotkeys[.retile]!, for: .retile), [])
    }
}
