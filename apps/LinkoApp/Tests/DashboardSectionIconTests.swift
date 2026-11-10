import AppKit
import XCTest

final class DashboardSectionIconTests: XCTestCase {
    /// A name with no matching asset draws an empty icon and reports no error.
    func testEverySectionIconIsInTheAssetCatalog() {
        let bundle = Bundle(for: Self.self)
        for section in DashboardSection.allCases {
            XCTAssertNotNil(
                bundle.image(forResource: section.iconName),
                "No image asset named \(section.iconName) for \(section)"
            )
        }
    }

    /// Two sections with the same icon cannot be told apart at a glance.
    func testEverySectionHasItsOwnIcon() {
        let names = DashboardSection.allCases.map(\.iconName)
        XCTAssertEqual(Set(names).count, names.count)
    }
}
