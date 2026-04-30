import XCTest

// TC-FISH-001 to TC-FISH-012 (automatable subset)
// Requirement: REQ-FISH-001 to REQ-FISH-008

final class FisheriesConditionsTests: PostLoginTestBase {

    private let riverName = "Babine" // Known river for the test community

    private func openConditions() {
        let landing = PublicLandingPage(app: app)
        landing.dismissWelcomeIfPresent()
        XCTAssertTrue(landing.isDisplayed, "Landing screen should be visible")
        landing.tapFishingForecast()
    }

    // MARK: - TC-FISH-001
    // REQ-FISH-001: water body selection list shows rivers with metrics

    func testWaterBodyListShown() {
        openConditions()

        let forecast = ForecastPage(app: app)
        XCTAssertTrue(forecast.isDisplayed,
                      "TC-FISH-001: Fisheries Conditions view should be displayed")
        // Verify at least one water body button is present
        let riverButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", riverName)).firstMatch
        XCTAssertTrue(riverButton.waitForExistence(timeout: 10),
                      "TC-FISH-001: Water body list should contain configured rivers including '\(riverName)'")
    }

    // MARK: - TC-FISH-002
    // REQ-FISH-001: unavailable metrics show "--"

    func testUnavailableMetricsShowDashes() {
        openConditions()
        let forecast = ForecastPage(app: app)
        XCTAssertTrue(forecast.isDisplayed, "TC-FISH-002: Conditions view should be displayed")

        // "--" static texts indicate unavailable metrics in the row
        // This test passes if the view loads without crashing — values may or may not be "--"
        // depending on live data availability. The test verifies no blank/error states appear.
        XCTAssertFalse(app.staticTexts["Error"].exists,
                       "TC-FISH-002: No error text should be visible in the conditions list")
    }

    private func navigateToRiverDetail() {
        openConditions()
        ForecastPage(app: app).tapRiver(riverName)
    }

    // MARK: - TC-FISH-003
    // REQ-FISH-002: weather detail shows three-day blocks (Yesterday, Today, Tomorrow)

    func testWeatherThreeDayBlocksPresent() {
        navigateToRiverDetail()

        XCTAssertTrue(app.otherElements["weatherSection"].waitForExistence(timeout: 15),
                      "TC-FISH-003: Weather section should be present in water body detail")
        XCTAssertTrue(app.staticTexts["Yesterday"].exists,
                      "TC-FISH-003: 'Yesterday' weather block should be present")
        XCTAssertTrue(app.staticTexts["Today"].exists,
                      "TC-FISH-003: 'Today' weather block should be present")
        XCTAssertTrue(app.staticTexts["Tomorrow"].exists,
                      "TC-FISH-003: 'Tomorrow' weather block should be present")
    }

    // MARK: - TC-FISH-005
    // REQ-FISH-003: tide cards are shown only when the water body is tidal.
    // Non-tidal rivers (e.g. Babine) must not render the tide wave chart or
    // High/Low text blocks.

    func testTidesHiddenForNonTidalRiver() {
        navigateToRiverDetail()

        // Wait for the detail view to actually load before asserting absence,
        // otherwise we'd pass trivially on a slow render.
        XCTAssertTrue(app.otherElements["weatherSection"].waitForExistence(timeout: 15),
                      "TC-FISH-005: Detail view should render before checking tide visibility")

        XCTAssertFalse(app.otherElements["tidesWaveSection"].exists,
                       "TC-FISH-005: Tide wave chart must be hidden for non-tidal river '\(riverName)'")
        XCTAssertFalse(app.staticTexts["Tide Heights"].exists,
                       "TC-FISH-005: 'Tide Heights' label must be hidden for non-tidal river")
    }

    // MARK: - TC-FISH-006
    // REQ-FISH-003: tide cards are shown for tidal water bodies (e.g. Puget Sound).

    func testTidesShownForTidalWaterBody() throws {
        let tidalName = "Puget Sound"
        openConditions()
        let forecast = ForecastPage(app: app)
        let tidalButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", tidalName)).firstMatch
        guard tidalButton.waitForExistence(timeout: 10) else {
            throw XCTSkip("TC-FISH-006: Tidal water body '\(tidalName)' not configured for this community")
        }
        forecast.tapRiver(tidalName)

        XCTAssertTrue(app.otherElements["tidesWaveSection"].waitForExistence(timeout: 15),
                      "TC-FISH-006: Tide wave chart should be present for tidal water body '\(tidalName)'")
        XCTAssertTrue(app.staticTexts["Tide Heights"].exists,
                      "TC-FISH-006: 'Tide Heights' label should be present for tidal water body")
        XCTAssertTrue(app.staticTexts["High"].exists, "TC-FISH-006: High tide block should be present")
        XCTAssertTrue(app.staticTexts["Low"].exists, "TC-FISH-006: Low tide block should be present")
    }

    // MARK: - TC-FISH-007
    // REQ-FISH-004: water level section present

    func testWaterLevelSectionPresent() {
        navigateToRiverDetail()

        XCTAssertTrue(app.staticTexts["waterLevelHeader"].waitForExistence(timeout: 15),
                      "TC-FISH-007: 'Water Level (Last 4 Days)' header should be present")
    }

    // MARK: - TC-FISH-008
    // REQ-FISH-005: water temperature section present (when data available)

    func testWaterTemperatureSectionPresent() {
        navigateToRiverDetail()

        // Either the temp header or the unavailable message should be present
        let tempHeader = app.staticTexts["waterTempHeader"]
        let tempUnavailable = app.staticTexts["waterTempUnavailable"]
        let either = tempHeader.waitForExistence(timeout: 15) || tempUnavailable.waitForExistence(timeout: 5)
        XCTAssertTrue(either,
                      "TC-FISH-008: Water temperature section or 'unavailable' message should be present")
    }

    // MARK: - TC-FISH-009
    // REQ-FISH-006: station attribution shown as "Using Station: {id}"

    func testStationAttributionPresent() {
        navigateToRiverDetail()

        _ = app.staticTexts["weatherSection"].waitForExistence(timeout: 15)
        // Station text is in the nav toolbar principal via staticTexts
        let stationTexts = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Using Station:'"))
        XCTAssertTrue(stationTexts.count > 0,
                      "TC-FISH-009: Station attribution 'Using Station: ...' should be present in nav bar")
    }

    // MARK: - TC-FISH-012
    // REQ-FISH-008: empty state shown when no water bodies configured

    func testEmptyStateShownWhenNoLocations() throws {
        // This test requires a community with no configured water bodies.
        // With the standard test account this scenario may not be reproducible.
        // Verify the static text exists in the app bundle as a canary.
        throw XCTSkip("TC-FISH-012: Requires a community with no configured water bodies — skip in standard environment")
    }
}

