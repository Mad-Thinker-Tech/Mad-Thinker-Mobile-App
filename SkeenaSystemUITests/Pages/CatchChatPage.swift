import XCTest

/// Page Object for the Researcher catch-chat flow (CatchChatView).
///
/// Drives the conversation step-by-step using the `chatCapsule_<id>`
/// accessibility identifiers added to the capsule row, plus the side-column
/// buttons (`chatPhotoUploadButton`, `chatHeadConfirmButton`,
/// `researcherFinalConfirmButton`, etc.). The photo picker is bypassed via
/// the `-uiTesting` photo-injection hook in `CatchChatView` — tapping the
/// upload button immediately routes a fixture image into the view model
/// without ever presenting `PHPickerViewController`.
struct CatchChatPage {
    let app: XCUIApplication

    // MARK: - Activity choice

    var chooseCatchCapsule: XCUIElement { app.buttons["chatCapsule_activity-catch"] }
    var chooseCatchSideButton: XCUIElement { app.buttons["chatChooseCatchButton"] }

    // MARK: - Photo upload + head confirmation

    var photoUploadButton: XCUIElement { app.buttons["chatPhotoUploadButton"] }
    var headConfirmButton: XCUIElement { app.buttons["chatHeadConfirmButton"] }
    var headRetakeButton: XCUIElement { app.buttons["chatHeadRetakeButton"] }

    // MARK: - Capsules (by id)

    func capsule(_ id: String) -> XCUIElement {
        app.buttons["chatCapsule_\(id)"]
    }

    /// First on-screen capsule whose id starts with `prefix`. Used when the
    /// exact capsule id is dynamic (species name, lifecycle stage, sex value).
    func firstCapsule(withIDPrefix prefix: String) -> XCUIElement {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "chatCapsule_\(prefix)")
        return app.buttons.matching(predicate).firstMatch
    }

    // MARK: - Side-column step buttons

    var researcherFinalConfirmButton: XCUIElement { app.buttons["researcherFinalConfirmButton"] }
    var researcherStepConfirmButton: XCUIElement { app.buttons["researcherStepConfirmButton"] }

    // MARK: - Reset

    var resetButton: XCUIElement { app.buttons["chatResetButton"] }

    // MARK: - Convenience

    /// Coordinate-tap helper for any side-column SwiftUI Button. Mirrors the
    /// capsule workaround above — `.tap()` fails on iOS 26 inside ScrollViews.
    @discardableResult
    func tap(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return true
    }

    /// Tap a capsule by id, waiting up to `timeout` for it to appear first.
    /// Returns true on a successful tap, false if the capsule never appeared.
    ///
    /// Uses a frame-coordinate tap rather than `XCUIElement.tap()` because
    /// SwiftUI `Button(...).buttonStyle(.plain)` elements inside a ScrollView
    /// report `{-1, -1}` hit points to XCUITest on iOS 26, making the
    /// framework's hit-testing fail with "Not hittable" even when the button
    /// is fully visible. Same workaround as the community toolbar button.
    @discardableResult
    func tapCapsule(_ id: String, timeout: TimeInterval = 30) -> Bool {
        let cap = capsule(id)
        guard cap.waitForExistence(timeout: timeout) else { return false }
        cap.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return true
    }

    /// Tap the first capsule whose id starts with `prefix` (waiting for it).
    @discardableResult
    func tapFirstCapsule(withIDPrefix prefix: String, timeout: TimeInterval = 30) -> Bool {
        let cap = firstCapsule(withIDPrefix: prefix)
        guard cap.waitForExistence(timeout: timeout) else { return false }
        cap.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return true
    }

    /// Tap the SECOND capsule whose id starts with `prefix`, used when the
    /// test wants to override the ML pick (which is always rendered first).
    /// E.g. `tapSecondCapsule(withIDPrefix: "lc-")` flips Holding → Traveler
    /// (or vice-versa); `tapSecondCapsule(withIDPrefix: "sex-")` chooses the
    /// opposite-sex alternative instead of the ML guess.
    @discardableResult
    func tapSecondCapsule(withIDPrefix prefix: String, timeout: TimeInterval = 30) -> Bool {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "chatCapsule_\(prefix)")
        let matches = app.buttons.matching(predicate)
        // Wait for at least the first capsule, then read the count.
        guard matches.firstMatch.waitForExistence(timeout: timeout) else { return false }
        guard matches.count >= 2 else { return false }
        let second = matches.element(boundBy: 1)
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return true
    }

    // MARK: - Input bar

    var inputField: XCUIElement { app.textFields["chatInputField"] }
    var sendButton: XCUIElement { app.buttons["chatSendButton"] }

    /// Type `text` into the chat input bar and tap Send.
    ///
    /// SwiftUI lays out the chat's TextField with an AX-reported frame that
    /// is much taller than the visible input row — the bottom of the frame
    /// overlaps the role-landing's bottom toolbar buttons (Home, Activities,
    /// Maps, Learn). A default `.tap()` computes the hit point at the
    /// element centroid, which falls inside the toolbar overlap zone, so the
    /// tap routes to a toolbar button (commonly Activities) instead of the
    /// field. Tapping near the TOP of the frame lands inside the visible
    /// input row reliably. Same workaround pattern as the capsule taps.
    @discardableResult
    func sendText(_ text: String, timeout: TimeInterval = 15) -> Bool {
        guard inputField.waitForExistence(timeout: timeout) else { return false }
        inputField.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        inputField.typeText(text)
        guard sendButton.waitForExistence(timeout: 5) else { return false }
        sendButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return true
    }

    // MARK: - Bubble inspection

    /// Find the first numeric value in any visible static text containing
    /// `prefix` (case-sensitive). Used to read ML estimates out of the
    /// length/girth confirmation bubbles ("Estimated length: 28 inches" or
    /// "Estimated girth: 14.5 inches"). Returns nil if no such bubble appears
    /// within `timeout`, or if the text holds no parseable number.
    func numericValue(inBubbleContaining prefix: String, timeout: TimeInterval = 15) -> Double? {
        let predicate = NSPredicate(format: "label CONTAINS %@", prefix)
        let bubble = app.staticTexts.matching(predicate).firstMatch
        guard bubble.waitForExistence(timeout: timeout) else { return nil }
        return Self.firstNumber(in: bubble.label)
    }

    /// Returns the first decimal number embedded in `text` (e.g. "Estimated
    /// length: 28.5 inches" → 28.5; "Estimated length: 19-23 inches" → 19,
    /// the lower bound of the range, which is what the test should add or
    /// subtract from). Strips a trailing "+" used by length-at-species-cap
    /// formatting before parsing.
    static func firstNumber(in text: String) -> Double? {
        let pattern = #"(\d+(?:\.\d+)?)"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Double(text[range])
    }
}
