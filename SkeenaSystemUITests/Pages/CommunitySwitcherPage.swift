import XCTest
import CoreFoundation

/// Page Object for the in-app community switcher.
///
/// Wraps the toolbar entry button (`CommunityToolbarButton` /
/// `CommunitySwitcherChevron`) and the `CommunitySwitcherSheet` it presents.
/// The toolbar button's accessibility identifier embeds the active community
/// name (`communityToolbarButton_<name>`) so it doubles as the identity probe
/// for "which community is active right now?".
struct CommunitySwitcherPage {
    let app: XCUIApplication

    private static let toolbarPrefix = "communityToolbarButton_"

    // MARK: - Elements

    /// Currently visible toolbar button (any community). Used for tapping to
    /// open the switcher sheet without caring which community we're on.
    var toolbarButton: XCUIElement {
        let predicate = NSPredicate(format:
            "identifier BEGINSWITH %@ AND identifier != %@",
            Self.toolbarPrefix, Self.toolbarPrefix)
        return app.buttons.matching(predicate).firstMatch
    }

    /// Toolbar button when a specific community is active.
    func toolbarButton(for name: String) -> XCUIElement {
        app.buttons["\(Self.toolbarPrefix)\(name)"]
    }

    /// Row in the open switcher sheet for a given community name.
    func row(named name: String) -> XCUIElement {
        app.buttons["communitySwitcherRow_\(name)"]
    }

    /// "Done" button in the switcher sheet's nav bar.
    var doneButton: XCUIElement { app.buttons["Done"] }

    // MARK: - Actions

    /// Returns the active community's display name by reading the toolbar
    /// button's `communityToolbarButton_<name>` identifier, or `nil` if no
    /// community-aware toolbar button appears within `timeout`.
    func currentCommunityName(timeout: TimeInterval = 20) -> String? {
        let predicate = NSPredicate(format:
            "identifier BEGINSWITH %@ AND identifier != %@",
            Self.toolbarPrefix, Self.toolbarPrefix)
        let query = app.buttons.matching(predicate)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if query.count > 0 {
                let id = query.element(boundBy: 0).identifier
                return String(id.dropFirst(Self.toolbarPrefix.count))
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    /// Toggles the active community via Darwin notification (the app-side
    /// observer is registered in SkeenaSystemApp when `-uiTesting` is set).
    /// Used because SwiftUI ToolbarItem buttons in NavigationStack can't be
    /// tapped reliably from XCUITest on iOS 26 — same workaround pattern as
    /// `LoginPage.signOut()`.
    ///
    /// Returns true if a `communityToolbarButton_<expectedName>` appears on
    /// the resulting landing view within `timeout`.
    @discardableResult
    func toggleAndExpect(_ expectedName: String, timeout: TimeInterval = 20) -> Bool {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("com.madthinker.uitest.toggleCommunity" as CFString),
            nil, nil, true
        )
        return toolbarButton(for: expectedName).waitForExistence(timeout: timeout)
    }
}
