import AppKit
import XCTest

final class DashboardSectionIconTests: XCTestCase {
    /// An unknown SF Symbol name draws an empty tile and reports no error.
    func testEverySectionIconIsAKnownSymbol() {
        for section in DashboardSection.allCases {
            let name = section.iconStyle.symbolName
            XCTAssertNotNil(
                NSImage(systemSymbolName: name, accessibilityDescription: nil),
                "No SF Symbol named \(name) for \(section)"
            )
        }
    }

    /// Two sections with the same glyph cannot be told apart at a glance.
    func testEverySectionHasItsOwnGlyph() {
        let names = DashboardSection.allCases.map(\.iconStyle.symbolName)
        XCTAssertEqual(Set(names).count, names.count)
    }

    /// Rows that share a tile color in one sidebar group read as one item.
    func testNoSidebarGroupRepeatsATileColor() {
        let groups = [
            DashboardSection.monitoringSections,
            DashboardSection.profileSections,
            DashboardSection.subscriptionSections,
            DashboardSection.routingSections,
        ]
        for group in groups {
            let palettes = group.map(\.iconStyle.palette)
            for (index, palette) in palettes.enumerated() {
                XCTAssertFalse(palettes[..<index].contains(palette), "\(group[index]) repeats a tile color")
            }
        }
    }
}
