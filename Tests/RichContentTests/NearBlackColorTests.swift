import XCTest
@testable import RichContent

final class NearBlackColorTests: XCTestCase {

    private func hex(_ value: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha)
    }

    func testBlackAndDarkGraysAreNearBlack() {
        for value: UInt32 in [0x000000, 0x222222, 0x333333, 0x444444, 0x555555, 0x666666, 0x2C3E50] {
            XCTAssertTrue(hex(value).isNearBlack, String(format: "#%06X", value))
        }
    }

    func testLighterGraysAndColoredTextAreNot() {
        for value: UInt32 in [0x777777, 0x999999, 0x1A237E, 0x800000, 0x1B5E20, 0x0000EE] {
            XCTAssertFalse(hex(value).isNearBlack, String(format: "#%06X", value))
        }
    }

    func testTranslucentDarkIsNot() {
        XCTAssertFalse(hex(0x333333, alpha: 0.5).isNearBlack)
    }
}
