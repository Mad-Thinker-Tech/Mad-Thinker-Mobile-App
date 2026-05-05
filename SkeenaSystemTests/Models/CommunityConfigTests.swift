import XCTest
@testable import SkeenaSystem

/// Tests for CommunityConfig — verifies the flag fallback chain,
/// branding resolution, JSON decoding, and the CommunityInfo.config merge.
final class CommunityConfigTests: XCTestCase {

    // MARK: - Flag Fallback Chain

    func testFlag_returnsBackendValue_whenPresent() {
        let config = CommunityConfig(
            logoUrl: nil, logoAssetName: nil, tagline: nil, displayName: nil, learnUrl: nil,
            entitlements: ["E_TEST_FLAG": true],
            geography: .empty,
            units: nil
        )
        XCTAssertTrue(config.flag("E_TEST_FLAG"),
                      "Should return backend value when key is present")
    }

    func testFlag_returnsBackendFalse_whenExplicitlyFalse() {
        let config = CommunityConfig(
            logoUrl: nil, logoAssetName: nil, tagline: nil, displayName: nil, learnUrl: nil,
            entitlements: ["E_TEST_FLAG": false],
            geography: .empty,
            units: nil
        )
        XCTAssertFalse(config.flag("E_TEST_FLAG"),
                       "Should return false when backend explicitly sets it to false")
    }

    func testFlag_fallsBackToXcconfig_whenKeyAbsent() {
        let config = CommunityConfig.default
        // E_CATCH_CAROUSEL is true in DevTEST xcconfig
        let xcconfigValue = readEntitlement("E_CATCH_CAROUSEL")
        XCTAssertEqual(config.flag("E_CATCH_CAROUSEL"), xcconfigValue,
                       "Should fall back to xcconfig when key absent from backend")
    }

    func testFlag_returnsFalse_whenKeyAbsentFromBothSources() {
        let config = CommunityConfig.default
        XCTAssertFalse(config.flag("E_NONEXISTENT_12345"),
                       "Should return false when key absent from both backend and xcconfig")
    }

    func testFlag_backendOverridesXcconfig() {
        // E_CATCH_CAROUSEL is true in DevTEST xcconfig — backend overrides to false
        let config = CommunityConfig(
            logoUrl: nil, logoAssetName: nil, tagline: nil, displayName: nil, learnUrl: nil,
            entitlements: ["E_CATCH_CAROUSEL": false],
            geography: .empty,
            units: nil
        )
        XCTAssertFalse(config.flag("E_CATCH_CAROUSEL"),
                       "Backend value should override xcconfig value")
    }

    // MARK: - Branding Resolution

    func testResolvedLogoAssetName_returnsBackendValue_whenPresent() {
        let config = CommunityConfig(
            logoUrl: nil, logoAssetName: "BendFlyShopLogo", tagline: nil, displayName: nil, learnUrl: nil,
            entitlements: [:],
            geography: .empty,
            units: nil
        )
        XCTAssertEqual(config.resolvedLogoAssetName, "BendFlyShopLogo")
    }

    func testResolvedLogoAssetName_fallsBackToXcconfig_whenNil() {
        let config = CommunityConfig.default
        XCTAssertEqual(config.resolvedLogoAssetName, AppEnvironment.shared.appLogoAsset,
                       "Should fall back to xcconfig APP_LOGO_ASSET")
    }

    func testResolvedLogoAssetName_fallsBackToXcconfig_whenEmpty() {
        let config = CommunityConfig(
            logoUrl: nil, logoAssetName: "", tagline: nil, displayName: nil, learnUrl: nil,
            entitlements: [:],
            geography: .empty,
            units: nil
        )
        XCTAssertEqual(config.resolvedLogoAssetName, AppEnvironment.shared.appLogoAsset,
                       "Should fall back to xcconfig when asset name is empty string")
    }

    func testResolvedDisplayName_returnsBackendValue_whenPresent() {
        let config = CommunityConfig(
            logoUrl: nil, logoAssetName: nil, tagline: nil, displayName: "Custom Name", learnUrl: nil,
            entitlements: [:],
            geography: .empty,
            units: nil
        )
        XCTAssertEqual(config.resolvedDisplayName, "Custom Name")
    }

    func testResolvedDisplayName_fallsBackToXcconfig_whenNil() {
        let config = CommunityConfig.default
        XCTAssertEqual(config.resolvedDisplayName, AppEnvironment.shared.appDisplayName)
    }

    func testResolvedTagline_returnsBackendValue_whenPresent() {
        let config = CommunityConfig(
            logoUrl: nil, logoAssetName: nil, tagline: "Custom Tagline", displayName: nil, learnUrl: nil,
            entitlements: [:],
            geography: .empty,
            units: nil
        )
        XCTAssertEqual(config.resolvedTagline, "Custom Tagline")
    }

    // MARK: - Default Config

    func testDefault_hasEmptyFeatureFlags() {
        XCTAssertTrue(CommunityConfig.default.entitlements.isEmpty,
                      "Default config should have no backend entitlements")
    }

    func testDefault_hasNilBranding() {
        let d = CommunityConfig.default
        XCTAssertNil(d.logoUrl)
        XCTAssertNil(d.logoAssetName)
        XCTAssertNil(d.tagline)
        XCTAssertNil(d.displayName)
    }

    // MARK: - JSON Decoding

    func testDecoding_fullConfig() throws {
        let json = """
        {
            "logoUrl": "https://example.com/logo.png",
            "logoAssetName": "TestLogo",
            "tagline": "Test Tagline",
            "displayName": "Test Community",
            "learnUrl": "https://example.com/learn",
            "entitlements": {"E_MEET_STAFF": true, "E_FLIGHT_INFO": false},
            "geography": {"default_river": "Hoh River", "lodge_rivers": ["Hoh River", "Green River"], "forecast_location": "Western Washington"}
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(CommunityConfig.self, from: json)

        XCTAssertEqual(config.logoUrl, "https://example.com/logo.png")
        XCTAssertEqual(config.logoAssetName, "TestLogo")
        XCTAssertEqual(config.tagline, "Test Tagline")
        XCTAssertEqual(config.displayName, "Test Community")
        XCTAssertEqual(config.learnUrl, "https://example.com/learn")
        XCTAssertEqual(config.entitlements["E_MEET_STAFF"], true)
        XCTAssertEqual(config.entitlements["E_FLIGHT_INFO"], false)
        XCTAssertEqual(config.entitlements.count, 2)
    }

    func testDecoding_roundtrip() throws {
        let original = CommunityConfig(
            logoUrl: "https://example.com/logo.png",
            logoAssetName: "TestLogo",
            tagline: "Tagline",
            displayName: "Name",
            learnUrl: "https://example.com/learn",
            entitlements: ["E_A": true, "E_B": false],
            geography: CommunityGeography(
                defaultRiver: "Hoh River", lodgeRivers: ["Hoh River"],
                defaultWaterBody: "Puget Sound", lodgeWaterBodies: ["Puget Sound"],
                forecastLocation: "Western WA", defaultMapLatitude: 47.9, defaultMapLongitude: -122.8
            ),
            units: nil
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CommunityConfig.self, from: data)

        XCTAssertEqual(original, decoded, "Encode/decode roundtrip should produce equal config")
    }

    // MARK: - CommunityInfo.config Merge

    func testCommunityInfo_config_mergesBrandingAndFlags() {
        let typeInfo = CommunityTypeInfo(
            id: "type-1",
            name: "Lodge",
            entitlements: ["E_MEET_STAFF": true, "E_FLIGHT_INFO": false]
        )

        let communityInfo = CommunityInfo(
            id: "comm-1",
            name: "Test Lodge",
            code: "ABC123",
            isActive: true,
            communityTypeId: "type-1",
            logoUrl: "https://example.com/logo.png",
            logoAssetName: "TestLogo",
            tagline: "Welcome",
            displayName: "Test Lodge Display",
            learnUrl: nil,
            customUrls: nil,
            donationUrl: nil,
            donationDescription: nil,
            geography: CommunityGeography(
                defaultRiver: "Hoh River", lodgeRivers: ["Hoh River", "Green River"],
                defaultWaterBody: nil, lodgeWaterBodies: nil,
                forecastLocation: "Western WA", defaultMapLatitude: 47.9, defaultMapLongitude: -122.8
            ),
            units: nil,
            communityTypes: typeInfo
        )

        let config = communityInfo.config

        // Branding from community
        XCTAssertEqual(config.logoUrl, "https://example.com/logo.png")
        XCTAssertEqual(config.logoAssetName, "TestLogo")
        XCTAssertEqual(config.tagline, "Welcome")
        XCTAssertEqual(config.displayName, "Test Lodge Display")

        // Flags from type
        XCTAssertTrue(config.flag("E_MEET_STAFF"))
        XCTAssertFalse(config.flag("E_FLIGHT_INFO"))
    }

    func testCommunityInfo_config_withNilType_returnsEmptyFlags() {
        let communityInfo = CommunityInfo(
            id: "comm-1",
            name: "Test",
            code: "ABC123",
            isActive: true,
            communityTypeId: nil,
            logoUrl: nil,
            logoAssetName: nil,
            tagline: nil,
            displayName: nil,
            learnUrl: nil,
            customUrls: nil,
            donationUrl: nil,
            donationDescription: nil,
            geography: nil,
            units: nil,
            communityTypes: nil
        )

        let config = communityInfo.config

        XCTAssertTrue(config.entitlements.isEmpty,
                      "Config should have empty entitlements when community has no type")
    }

    // MARK: - Equatable

    func testEquatable_sameValues_areEqual() {
        let a = CommunityConfig(
            logoUrl: "url", logoAssetName: "asset", tagline: "tag", displayName: "name", learnUrl: nil,
            entitlements: ["E_A": true], geography: .empty, units: nil
        )
        let b = CommunityConfig(
            logoUrl: "url", logoAssetName: "asset", tagline: "tag", displayName: "name", learnUrl: nil,
            entitlements: ["E_A": true], geography: .empty, units: nil
        )
        XCTAssertEqual(a, b)
    }

    func testEquatable_differentFlags_areNotEqual() {
        let a = CommunityConfig(
            logoUrl: nil, logoAssetName: nil, tagline: nil, displayName: nil, learnUrl: nil,
            entitlements: ["E_A": true], geography: .empty, units: nil
        )
        let b = CommunityConfig(
            logoUrl: nil, logoAssetName: nil, tagline: nil, displayName: nil, learnUrl: nil,
            entitlements: ["E_A": false], geography: .empty, units: nil
        )
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Geography Resolution

    func testResolvedGeography_returnsBackendValues_whenPresent() {
        let geo = CommunityGeography(
            defaultRiver: "Skeena River",
            lodgeRivers: ["Skeena River", "Kispiox River"],
            defaultWaterBody: "Pacific Ocean",
            lodgeWaterBodies: ["Pacific Ocean"],
            forecastLocation: "Northern BC",
            defaultMapLatitude: 54.5,
            defaultMapLongitude: -128.6
        )
        let config = CommunityConfig(
            logoUrl: nil, logoAssetName: nil, tagline: nil, displayName: nil, learnUrl: nil,
            entitlements: [:], geography: geo,
            units: nil
        )

        XCTAssertEqual(config.resolvedDefaultRiver, "Skeena River")
        XCTAssertEqual(config.resolvedLodgeRivers, ["Skeena River", "Kispiox River"])
        XCTAssertEqual(config.resolvedDefaultWaterBody, "Pacific Ocean")
        XCTAssertEqual(config.resolvedLodgeWaterBodies, ["Pacific Ocean"])
        XCTAssertEqual(config.resolvedForecastLocation, "Northern BC")
        XCTAssertEqual(config.resolvedDefaultMapLatitude, 54.5)
        XCTAssertEqual(config.resolvedDefaultMapLongitude, -128.6)
    }

    func testResolvedGeography_returnsNilAndEmpty_whenNotConfigured() {
        let config = CommunityConfig.default

        XCTAssertNil(config.resolvedDefaultRiver, "Should be nil when no geography configured")
        XCTAssertTrue(config.resolvedLodgeRivers.isEmpty, "Should be empty when no geography configured")
        XCTAssertNil(config.resolvedForecastLocation, "Should be nil when no geography configured")
        XCTAssertNil(config.resolvedDefaultMapLatitude, "Should be nil when no geography configured")
        XCTAssertNil(config.resolvedDefaultMapLongitude, "Should be nil when no geography configured")
        XCTAssertFalse(config.hasGeography, "hasGeography should be false when nothing configured")
    }

    func testHasGeography_trueWhenRiversConfigured() {
        let geo = CommunityGeography(
            defaultRiver: nil, lodgeRivers: ["Test River"],
            defaultWaterBody: nil, lodgeWaterBodies: nil,
            forecastLocation: nil, defaultMapLatitude: nil, defaultMapLongitude: nil
        )
        let config = CommunityConfig(
            logoUrl: nil, logoAssetName: nil, tagline: nil, displayName: nil, learnUrl: nil,
            entitlements: [:], geography: geo,
            units: nil
        )
        XCTAssertTrue(config.hasGeography)
    }

    // MARK: - Learn URL Resolution

    func testResolvedLearnUrl_returnsBackendValue_whenPresent() {
        let config = CommunityConfig(
            logoUrl: nil, logoAssetName: nil, tagline: nil, displayName: nil,
            learnUrl: "https://community.example.com/learn",
            entitlements: [:], geography: .empty, units: nil
        )
        XCTAssertEqual(config.resolvedLearnUrl, "https://community.example.com/learn")
    }

    func testResolvedLearnUrl_fallsBackToXcconfig_whenNil() {
        let config = CommunityConfig(
            logoUrl: nil, logoAssetName: nil, tagline: nil, displayName: nil, learnUrl: nil,
            entitlements: [:], geography: .empty, units: nil
        )
        XCTAssertEqual(config.resolvedLearnUrl, AppEnvironment.shared.defaultLearnURL,
                       "Should fall back to xcconfig DEFAULT_LEARN_URL when learnUrl is nil")
    }

    func testResolvedLearnUrl_fallsBackToXcconfig_whenEmpty() {
        let config = CommunityConfig(
            logoUrl: nil, logoAssetName: nil, tagline: nil, displayName: nil, learnUrl: "",
            entitlements: [:], geography: .empty, units: nil
        )
        XCTAssertEqual(config.resolvedLearnUrl, AppEnvironment.shared.defaultLearnURL,
                       "Should fall back to xcconfig DEFAULT_LEARN_URL when learnUrl is empty string")
    }

    func testCommunityInfo_config_passesLearnUrlThrough() {
        let communityInfo = CommunityInfo(
            id: "comm-1",
            name: "Test",
            code: "TST001",
            isActive: true,
            communityTypeId: nil,
            logoUrl: nil,
            logoAssetName: nil,
            tagline: nil,
            displayName: nil,
            learnUrl: "https://custom.example.com/tutorials",
            customUrls: nil,
            donationUrl: nil,
            donationDescription: nil,
            geography: nil,
            units: nil,
            communityTypes: nil
        )
        XCTAssertEqual(communityInfo.config.resolvedLearnUrl, "https://custom.example.com/tutorials")
    }

    // MARK: - Unit Conversion

    /// `units == "imperial"` → isImperial true. Anything else (including nil)
    /// is treated as metric so a community-config payload that omits the field
    /// degrades to the SI defaults rather than silently doing F/ft conversion.
    func testIsImperial_resolution() {
        XCTAssertTrue(makeConfig(units: "imperial").isImperial)
        XCTAssertFalse(makeConfig(units: "metric").isImperial)
        XCTAssertFalse(makeConfig(units: nil).isImperial)
        XCTAssertFalse(makeConfig(units: "Imperial").isImperial,
                       "Comparison is case-sensitive — backend contract is lowercase 'imperial'")
    }

    func testTempUnit_imperialAndMetric() {
        XCTAssertEqual(makeConfig(units: "imperial").tempUnit, "°F")
        XCTAssertEqual(makeConfig(units: "metric").tempUnit, "°C")
    }

    func testWaterLevelUnit_imperialAndMetric() {
        XCTAssertEqual(makeConfig(units: "imperial").waterLevelUnit, "ft")
        XCTAssertEqual(makeConfig(units: "metric").waterLevelUnit, "m")
    }

    /// Backend always returns water temp in °C. Imperial communities convert
    /// to °F; metric passes through. `displayTempC` returns Double so callers
    /// own decimal formatting (the parallel Int helper `temperature(_:)` is
    /// for callers that want a rounded integer).
    func testDisplayTempC_metricPassthrough() {
        XCTAssertEqual(makeConfig(units: "metric").displayTempC(0),  0,  accuracy: 0.0001)
        XCTAssertEqual(makeConfig(units: "metric").displayTempC(15), 15, accuracy: 0.0001)
        XCTAssertEqual(makeConfig(units: "metric").displayTempC(-5), -5, accuracy: 0.0001)
    }

    func testDisplayTempC_imperialConvertsCelsiusToFahrenheit() {
        let imperial = makeConfig(units: "imperial")
        XCTAssertEqual(imperial.displayTempC(0),    32.0, accuracy: 0.0001, "0 °C → 32 °F")
        XCTAssertEqual(imperial.displayTempC(100), 212.0, accuracy: 0.0001, "100 °C → 212 °F")
        XCTAssertEqual(imperial.displayTempC(15),   59.0, accuracy: 0.0001, "15 °C → 59 °F")
        XCTAssertEqual(imperial.displayTempC(-40), -40.0, accuracy: 0.0001, "−40 °C → −40 °F (the cross-over)")
    }

    /// Backend always returns water level in feet. Metric communities convert
    /// to meters; imperial passes through.
    func testDisplayLevelFt_imperialPassthrough() {
        let imperial = makeConfig(units: "imperial")
        XCTAssertEqual(imperial.displayLevelFt(0),    0,    accuracy: 0.0001)
        XCTAssertEqual(imperial.displayLevelFt(4.32), 4.32, accuracy: 0.0001)
    }

    func testDisplayLevelFt_metricConvertsFeetToMeters() {
        let metric = makeConfig(units: "metric")
        XCTAssertEqual(metric.displayLevelFt(0),    0.0,        accuracy: 0.0001)
        XCTAssertEqual(metric.displayLevelFt(1),    0.3048,     accuracy: 0.0001, "1 ft = 0.3048 m")
        XCTAssertEqual(metric.displayLevelFt(10),   3.048,      accuracy: 0.0001)
        XCTAssertEqual(metric.displayLevelFt(4.32), 1.316736,   accuracy: 0.0001)
    }

    /// `temperature(_:)` is the rounded-Int helper — distinct from the
    /// Double-returning `displayTempC(_:)`. Both share the same conversion
    /// math; this guards against one drifting away from the other.
    func testTemperature_intHelperRoundsToNearest() {
        XCTAssertEqual(makeConfig(units: "metric").temperature(15.4), 15)
        XCTAssertEqual(makeConfig(units: "metric").temperature(15.6), 16)
        XCTAssertEqual(makeConfig(units: "imperial").temperature(15), 59,  "15 °C → 59 °F")
        XCTAssertEqual(makeConfig(units: "imperial").temperature(0),  32,  "0 °C → 32 °F")
    }

    /// Wind speed: backend returns km/h; imperial converts to mph (rounded Int).
    func testWindSpeed_imperialConvertsKmhToMph() {
        XCTAssertEqual(makeConfig(units: "imperial").windSpeed(100), 62, "100 km/h ≈ 62.14 mph")
        XCTAssertEqual(makeConfig(units: "metric").windSpeed(100), 100, "metric passes through")
        XCTAssertEqual(makeConfig(units: "imperial").windUnit, "mph")
        XCTAssertEqual(makeConfig(units: "metric").windUnit, "km/h")
    }

    /// Length helper is for fish dimensions — backend stores inches; metric
    /// converts to cm. Imperial passes through.
    func testLength_metricConvertsInchesToCentimeters() {
        XCTAssertEqual(makeConfig(units: "metric").length(10), 25.4, accuracy: 0.0001, "10 in = 25.4 cm")
        XCTAssertEqual(makeConfig(units: "imperial").length(10), 10, accuracy: 0.0001)
        XCTAssertEqual(makeConfig(units: "imperial").lengthUnit, "in")
        XCTAssertEqual(makeConfig(units: "metric").lengthUnit, "cm")
    }

    /// Round-trip a typical canonical reading through both display helpers
    /// and back via the inverse formula. Catches cases where one of the
    /// constants drifts (e.g. someone "rounds" 0.3048 to 0.305).
    func testDisplayHelpers_roundTripFromCanonical() {
        let metric = makeConfig(units: "metric")
        let canonicalFeet = 4.32
        let displayedMeters = metric.displayLevelFt(canonicalFeet)
        let backToFeet = displayedMeters / 0.3048
        XCTAssertEqual(backToFeet, canonicalFeet, accuracy: 0.0001)

        let imperial = makeConfig(units: "imperial")
        let canonicalC = 12.5
        let displayedF = imperial.displayTempC(canonicalC)
        let backToC = (displayedF - 32) * 5.0 / 9.0
        XCTAssertEqual(backToC, canonicalC, accuracy: 0.0001)
    }

    // MARK: - Helpers

    /// Build a minimal CommunityConfig with the given units string. Other
    /// fields are nil/empty so each unit-conversion test stays focused.
    private func makeConfig(units: String?) -> CommunityConfig {
        CommunityConfig(
            logoUrl: nil, logoAssetName: nil, tagline: nil, displayName: nil, learnUrl: nil,
            entitlements: [:], geography: .empty,
            units: units
        )
    }
}
