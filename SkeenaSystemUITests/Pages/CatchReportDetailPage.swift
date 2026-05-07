import XCTest

/// Page Object for `CatchReportDetailView` — the screen pushed when the
/// user taps a row in the Activities → Reports list. Wraps the Edit/Save
/// toggle button and the editable per-field TextFields exposed via the
/// `catchDetailField_<Title>` identifier scheme on `editableTextField`.
struct CatchReportDetailPage {
    let app: XCUIApplication

    // MARK: - Toolbar

    var editButton: XCUIElement { app.buttons["catchDetailEditButton"] }
    var saveButton: XCUIElement { app.buttons["catchDetailSaveButton"] }

    // MARK: - Editable fields

    /// Field titles that match the labels on `editableTextField(title:text:)`
    /// in `ReportsListView.CatchReportDetailView`. Adding a new field on the
    /// detail view? Add the title here AND make sure the field is wrapped in
    /// `editableTextField(...)` so it picks up the identifier convention.
    enum Field: String {
        case species = "Species"
        case lifecycleStage = "Lifecycle Stage"
        case sex = "Sex"
        case river = "River"
        case guide = "Guide"
        case memberNumber = "Member Number"
    }

    func field(_ field: Field) -> XCUIElement {
        app.textFields["catchDetailField_\(field.rawValue)"]
    }

    // MARK: - Convenience

    /// Replace the value of `field` with `text`. The TextField only accepts
    /// edits while the detail view is in `isEditing` mode (toggled by
    /// tapping the Edit button), so call `editButton.tap()` first.
    @discardableResult
    func setField(_ field: Field, to text: String, timeout: TimeInterval = 10) -> Bool {
        let tf = self.field(field)
        guard tf.waitForExistence(timeout: timeout) else { return false }
        tf.tap()
        // Clear any existing value so the typed text replaces (not appends).
        if let current = tf.value as? String, !current.isEmpty {
            let backspaces = String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count)
            tf.typeText(backspaces)
        }
        tf.typeText(text)
        return true
    }
}
