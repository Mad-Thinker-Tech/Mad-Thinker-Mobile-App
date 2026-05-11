//
//  AppEnvironment.swift
//  SkeenaSystem
//
//  Centralized configuration manager with environment‑specific settings
//  (Supabase URLs, anon keys, function endpoints, logging level, etc.).
//

import Foundation

/// Controls how often the splash video plays after login.
public enum SplashVideoFrequency: String {
    /// Play a random video on every login.
    case always = "ALWAYS"
    /// Play only on the very first login (persisted across launches).
    case firstLogin = "FIRST_LOGIN"
    /// Play once per app launch session.
    case session = "SESSION"
}

public nonisolated final class AppEnvironment {
    public static let shared = AppEnvironment()

    // MARK: - Runtime override properties (optional)
    // These can be set in tests or at runtime to temporarily override configuration values.
    public var overrideProjectURL: URL?
    public var overrideAnonKey: String?
    public var overrideAppDisplayName: String?
    public var overrideAppLogoAsset: String?

    // Logging override
    public var overrideLogLevel: LogLevel?

    // New overrides for individual function endpoints
    public var overrideUploadCatchURL: URL?
    public var overrideManageTripURL: URL?
    public var overrideRiverConditionsURL: URL?
    public var overrideTacticsRecommendationsURL: URL?
    public var overrideDownloadCatchURL: URL?
    public var overrideAnglerForecastURL: URL?
    public var overrideClassifiedLicensesURL: URL?
    public var overrideCatchStoryURL: URL?
    public var overrideNotesUploadURL: URL?
    public var overrideAnglerProfileURL: URL?
    public var overrideMyProfileURL: URL?
    public var overrideDeleteAccountURL: URL?
    public var overrideAnglerContextURL: URL?
    public var overrideProficiencyURL: URL?
    public var overrideGearURL: URL?
    public var overrideObservationsURL: URL?
    public var overrideOpsTicketsURL: URL?
    public var overrideForecastLocation: String?
    public var overrideDefaultMapLatitude: Double?
    public var overrideDefaultMapLongitude: Double?
    public var overrideArchiveAfterDays: Int?
    public var overrideImageCompressionQuality: Double?
    public var overrideFishDetectMinConfidence: Double?
    public var overrideFishDefaultGirthRatio: Double?
    public var overridePersonDetectMinConfidence: Double?
    public var overrideHeuristicDiagFracStrength: Double?
    public var overrideFishBoxScaleFactor: Double?
    public var overrideFishPixelsPerInch: Double?
    public var overrideFishMinLengthInches: Double?
    public var overrideFishMaxLengthInches: Double?
    public var overrideFishEstimateLowFactor: Double?
    public var overrideFishEstimateHighFactor: Double?
    public var overrideUseLengthRegressor: Bool?
    public var overrideSpeciesDetectionThreshold: Double?
    public var overrideLodgeRivers: [String]?
    public var overrideCommunityName: String?
    public var overrideCommunityTagline: String?
    public var overrideDefaultRiver: String?
    public var overrideLodgeWaterBodies: [String]?
    public var overrideDefaultWaterBody: String?
    public var overrideTacticsEnabled: Bool?

    private init() {
        // Cache parsed CSV arrays once at init (avoids re-splitting on every access).
        if let raw = Bundle.main.object(forInfoDictionaryKey: "LODGE_RIVERS") as? String, !raw.isEmpty {
            _cachedLodgeRivers = raw.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        if let raw = Bundle.main.object(forInfoDictionaryKey: "LODGE_WATER_BODIES") as? String, !raw.isEmpty {
            _cachedLodgeWaterBodies = raw.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    /// Pre-parsed CSV values from Info.plist (set once in init).
    private var _cachedLodgeRivers: [String] = []
    private var _cachedLodgeWaterBodies: [String] = []

    // MARK: - Helpers to read from Info.plist

    private func stringFromInfo(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    private func urlFromInfo(_ key: String) -> URL? {
        if let s = stringFromInfo(key), !s.isEmpty {
            return URL(string: s)
        }
        return nil
    }

    // MARK: - Base config values

    /// Root API base URL (derived from API_BASE_URL; https:// is prepended if missing).
    public var projectURL: URL {
        if let url = overrideProjectURL { return url }
        // Read API_BASE_URL (no scheme). Normalize by prepending https:// if missing.
        if let raw = stringFromInfo("API_BASE_URL")?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let normalized: String
            if URL(string: raw)?.scheme == nil {
                normalized = "https://" + raw
            } else {
                normalized = raw
            }
            if let url = URL(string: normalized) { return url }
        }
        fatalError("API_BASE_URL not configured in Info.plist or override.")
    }

    /// Anonymous API key for Supabase.
    public var anonKey: String {
        if let v = overrideAnonKey { return v }
        if let v = stringFromInfo("SUPABASE_ANON_KEY") { return v }
        fatalError("SUPABASE_ANON_KEY not configured.")
    }


    /// Display name for the app/community (used in UI).
    public var appDisplayName: String {
        if let v = overrideAppDisplayName { return v }
        return stringFromInfo("APP_DISPLAY_NAME") ?? "Fly Shop"
    }

    /// Asset catalog name for the app logo image (used in headers, templates, etc.).
    public var appLogoAsset: String {
        if let v = overrideAppLogoAsset { return v }
        return stringFromInfo("APP_LOGO_ASSET") ?? "AppLogo"
    }

    /// Community name used for branding, API payloads, and Core Data seed.
    /// Falls back to COMMUNITY xcconfig key, then appDisplayName.
    public var communityName: String {
        if let v = overrideCommunityName { return v }
        if let v = stringFromInfo("COMMUNITY"), !v.isEmpty { return v }
        return appDisplayName
    }

    /// Community tagline displayed on login, landing, and header views.
    public var communityTagline: String {
        if let v = overrideCommunityTagline { return v }
        return stringFromInfo("COMMUNITY_TAGLINE") ?? "Your Fly Fishing Destination"
    }

    /// Default river name used when no GPS-based river is resolved.
    /// Falls back to DEFAULT_RIVER xcconfig key, then first lodgeRiver.
    public var defaultRiver: String {
        if let v = overrideDefaultRiver { return v }
        if let v = stringFromInfo("DEFAULT_RIVER"), !v.isEmpty { return v }
        return lodgeRivers.first.map { Self.stripRiverSuffix($0) } ?? "Unknown"
    }

    // MARK: - Logging configuration

    /// Logging level (debug, info, warning, error, none). Defaults to .debug in Debug builds and .error in Release.
    public var logLevel: LogLevel {
        if let override = overrideLogLevel { return override }
        if let levelString = stringFromInfo("LOG_LEVEL") {
            switch levelString.lowercased() {
            case "debug":
                return .debug
            case "info":
                return .info
            case "warning", "warn":
                return .warn
            case "error":
                return .error
            default:
                break
            }
        }
        // Fallback defaults
        #if DEBUG
        return .debug
        #else
        return .error
        #endif
    }

    // MARK: - Splash video configuration

    /// How often the splash video should play. Defaults to .session.
    public var splashVideoFrequency: SplashVideoFrequency {
        if let raw = stringFromInfo("SPLASH_VIDEO_FREQUENCY"),
           let freq = SplashVideoFrequency(rawValue: raw.uppercased()) {
            return freq
        }
        return .session
    }

    /// Maximum duration (in seconds) the splash video plays before auto-completing.
    public var splashVideoMaxDuration: TimeInterval {
        if let s = stringFromInfo("SPLASH_VIDEO_MAX_DURATION"), let v = Double(s) { return v }
        return 3.0
    }

    /// Whether splash video audio is muted. Defaults to false (audio ON).
    public var splashVideoMuted: Bool {
        if let raw = stringFromInfo("SPLASH_VIDEO_MUTED")?.uppercased() {
            return raw == "ON"
        }
        return false
    }

    // MARK: - Computed endpoints for individual functions

    /// Upload catch reports endpoint (version set in xcconfig).
    public var uploadCatchURL: URL {
        if let v = overrideUploadCatchURL { return v }
        if let url = urlFromInfo("UPLOAD_CATCH_URL") { return url }
        return projectURL.appendingPathComponent("/functions/v1/upload-catch-reports-v5")
    }

    /// Manage-trip endpoint (functions/v1/manage-trip).
    public var manageTripURL: URL {
        if let v = overrideManageTripURL { return v }
        if let url = urlFromInfo("MANAGE_TRIP_URL") { return url }
        return projectURL.appendingPathComponent("/functions/v1/manage-trip")
    }

    /// Default learn URL fallback (from xcconfig / Info.plist).
    /// xcconfig stores host+path only (no protocol) because // is treated as a comment.
    public var defaultLearnURL: String {
        if let host = stringFromInfo("DEFAULT_LEARN_HOST"), !host.isEmpty {
            return "https://\(host)"
        }
        return "https://howtoflyfish.orvis.com/video-lessons"
    }

    /// River conditions endpoint (functions/v1/river-conditions).
    public var riverConditionsURL: URL {
        if let v = overrideRiverConditionsURL { return v }
        if let url = urlFromInfo("RIVER_CONDITIONS_URL") { return url }
        return projectURL.appendingPathComponent("/functions/v1/river-conditions")
    }

    /// Tactics recommendations endpoint (functions/v1/tactics-recommendations).
    public var tacticsRecommendationsURL: URL {
        if let v = overrideTacticsRecommendationsURL { return v }
        if let url = urlFromInfo("TACTICS_RECOMMENDATIONS_URL") { return url }
        return projectURL.appendingPathComponent("/functions/v1/tactics-recommendations")
    }

    /// Download catch reports endpoint (functions/v1/download-catch-reports).
    public var downloadCatchURL: URL {
        if let v = overrideDownloadCatchURL { return v }
        if let url = urlFromInfo("DOWNLOAD_CATCH_URL") { return url }
        return projectURL.appendingPathComponent("/functions/v1/download-catch-reports")
    }

    /// Angler forecast endpoint (functions/v1/angler-forecast).
    public var anglerForecastURL: URL {
        if let v = overrideAnglerForecastURL { return v }
        if let url = urlFromInfo("ANGLER_FORECAST_URL") { return url }
        return projectURL.appendingPathComponent("/functions/v1/angler-forecast")
    }

    /// Classified licenses CRUD endpoint (functions/v1/classified-licenses).
    public var classifiedLicensesURL: URL {
        if let v = overrideClassifiedLicensesURL { return v }
        if let url = urlFromInfo("CLASSIFIED_LICENSES_URL") { return url }
        return projectURL.appendingPathComponent("/functions/v1/classified-licenses")
    }

    /// Catch-story endpoint (functions/v1/catch-story).
    public var catchStoryURL: URL {
        if let v = overrideCatchStoryURL { return v }
        if let url = urlFromInfo("CATCH_STORY_URL") { return url }
        return projectURL.appendingPathComponent("/functions/v1/catch-story")
    }

    /// Voice notes upload endpoint (functions/v1/notes).
    public var notesUploadURL: URL {
        if let v = overrideNotesUploadURL { return v }
        if let url = urlFromInfo("NOTES_UPLOAD_URL") { return url }
        return projectURL.appendingPathComponent("/functions/v1/notes")
    }

    /// Angler-profile endpoint (functions/v1/angler-profile).
    public var anglerProfileURL: URL {
        if let v = overrideAnglerProfileURL { return v }
        if let url = urlFromInfo("ANGLER_PROFILE_URL") { return url }
        return projectURL.appendingPathComponent("/functions/v1/angler-profile")
    }

    /// My-profile endpoint (functions/v1/my-profile).
    public var myProfileURL: URL {
        if let v = overrideMyProfileURL { return v }
        if let url = urlFromInfo("MY_PROFILE_URL") { return url }
        return projectURL.appendingPathComponent("/functions/v1/my-profile")
    }

    /// Delete-account endpoint (functions/v1/delete-account).
    public var deleteAccountURL: URL {
        if let v = overrideDeleteAccountURL { return v }
        if let raw = stringFromInfo("DELETE_ACCOUNT_URL")?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            // If raw is already a full URL with scheme, use it directly
            if let url = URL(string: raw), url.scheme != nil { return url }
            // Otherwise treat as relative path: append to projectURL
            let path = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
            return projectURL.appendingPathComponent(path)
        }
        return projectURL.appendingPathComponent("/functions/v1/delete-account")
    }

    /// Angler-context endpoint (functions/v1/angler-context).
    public var anglerContextURL: URL {
        if let v = overrideAnglerContextURL { return v }
        if let url = urlFromInfo("ANGLER_CONTEXT_URL") { return url }
        return projectURL.appendingPathComponent("/functions/v1/angler-context")
    }

    /// Proficiency endpoint (functions/v1/proficiency).
    public var proficiencyURL: URL {
        if let v = overrideProficiencyURL { return v }
        if let url = urlFromInfo("PROFICIENCY_URL") { return url }
        return projectURL.appendingPathComponent("/functions/v1/proficiency")
    }

    /// Gear endpoint (functions/v1/gear).
    public var gearURL: URL {
        if let v = overrideGearURL { return v }
        if let url = urlFromInfo("GEAR_URL") { return url }
        return projectURL.appendingPathComponent("/functions/v1/gear")
    }

    /// Observations upload endpoint (functions/v1/observations).
    public var observationsURL: URL {
        if let v = overrideObservationsURL { return v }
        if let raw = stringFromInfo("OBSERVATIONS_URL")?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            // If raw is already a full URL, use it directly
            if let url = URL(string: raw), url.scheme != nil { return url }
            // Otherwise treat as relative path: append to projectURL
            let path = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
            return projectURL.appendingPathComponent(path)
        }
        return projectURL.appendingPathComponent("functions/v1/observations")
    }

    /// Ops tickets endpoint (functions/v1/ops-tickets).
    public var opsTicketsURL: URL {
        if let v = overrideOpsTicketsURL { return v }
        if let raw = stringFromInfo("OPS_TICKETS_URL")?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            if let url = URL(string: raw), url.scheme != nil { return url }
            let path = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
            return projectURL.appendingPathComponent(path)
        }
        return projectURL.appendingPathComponent("functions/v1/ops-tickets")
    }

    // MARK: - Location configuration

    /// Feature flag: enables "Get Tactics" button and "Get extended forecast" link.
    /// Defaults to false. Set TACTICS_ENABLED = YES in xcconfig to enable.
    public var tacticsEnabled: Bool {
        if let v = overrideTacticsEnabled { return v }
        if let raw = stringFromInfo("TACTICS_ENABLED") {
            return ["YES", "TRUE", "1"].contains(raw.uppercased())
        }
        return false
    }

    /// Forecast location name (e.g., "Oregon Coast"). Used by the extended forecast feature.
    public var forecastLocation: String {
        if let v = overrideForecastLocation { return v }
        if let v = stringFromInfo("FORECAST_LOCATION"), !v.isEmpty { return v }
        return "Oregon Coast"
    }

    /// Default map center latitude (e.g., 47.6062 for Seattle, WA).
    public var defaultMapLatitude: Double {
        if let v = overrideDefaultMapLatitude { return v }
        if let s = stringFromInfo("DEFAULT_MAP_LATITUDE"), let v = Double(s) { return v }
        return 47.6062
    }

    /// Default map center longitude (e.g., -122.3321 for Seattle, WA).
    public var defaultMapLongitude: Double {
        if let v = overrideDefaultMapLongitude { return v }
        if let s = stringFromInfo("DEFAULT_MAP_LONGITUDE"), let v = Double(s) { return v }
        return -122.3321
    }

    // MARK: - Image configuration

    /// JPEG compression quality (0.0–1.0) used when saving or caching photos.
    public var imageCompressionQuality: CGFloat {
        if let v = overrideImageCompressionQuality { return CGFloat(v) }
        if let s = stringFromInfo("IMAGE_COMPRESSION_QUALITY"), let v = Double(s) { return CGFloat(v) }
        return 0.85
    }

    /// River names available for this lodge (e.g., "Nehalem River", "Wilson River").
    /// Used to build river condition tiles. Names are sent as-is to the river-conditions API.
    public var lodgeRivers: [String] {
        if let v = overrideLodgeRivers { return v }
        return _cachedLodgeRivers
    }

    /// Strips common water-body suffixes from a river name (e.g. "Nehalem River" → "Nehalem").
    static func stripRiverSuffix(_ name: String) -> String {
        for suffix in [" Creek", " River", " Lake", " Stream"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    // MARK: - Water bodies configuration

    /// Water body names available for this community (e.g., "Puget Sound", "Hood Canal").
    /// Used for polygon-based GPS detection and conditions forecasts.
    public var lodgeWaterBodies: [String] {
        if let v = overrideLodgeWaterBodies { return v }
        return _cachedLodgeWaterBodies
    }

    /// Default water body name when no GPS-based water body is resolved.
    public var defaultWaterBody: String? {
        if let v = overrideDefaultWaterBody { return v }
        if let v = stringFromInfo("DEFAULT_WATER_BODY"), !v.isEmpty { return v }
        return lodgeWaterBodies.first
    }

    // MARK: - Fish detection ML calibration

    /// Minimum confidence threshold for the primary fish detection candidate.
    public var fishDetectMinConfidence: Float {
        if let v = overrideFishDetectMinConfidence { return Float(v) }
        if let s = stringFromInfo("FISH_DETECT_MIN_CONFIDENCE"), let v = Float(s) { return v }
        return 0.08
    }

    /// Default girth-to-length ratio used when no species-specific ratio is available.
    public var fishDefaultGirthRatio: Double {
        if let v = overrideFishDefaultGirthRatio { return v }
        if let s = stringFromInfo("FISH_DEFAULT_GIRTH_RATIO"), let v = Double(s) { return v }
        return 0.5
    }

    /// Whole-day window after which an *uploaded* catch report or observation
    /// drops out of the active list and moves to the Archive view.
    /// Source: `ARCHIVE_AFTER_DAYS` (xcconfig → Info.plist). Defaults to 14.
    public var archiveAfterDays: Int {
        if let v = overrideArchiveAfterDays { return v }
        if let s = stringFromInfo("ARCHIVE_AFTER_DAYS"), let v = Int(s) { return v }
        return 14
    }

    /// Single source of truth for "is this record old enough to archive?".
    /// Locally-saved / pending records are never archived regardless of age —
    /// only uploaded records past the `archiveAfterDays` window flip true.
    /// Both catch reports and observations call this so the rule stays
    /// consistent across surfaces.
    public func shouldArchive(uploaded: Bool, createdAt: Date) -> Bool {
        guard uploaded else { return false }
        let cutoff = Calendar.current.date(byAdding: .day, value: -archiveAfterDays, to: Date()) ?? .distantPast
        return createdAt < cutoff
    }

    /// Minimum confidence threshold for the person detection box to be used as
    /// a length-scale reference. Below this, the analyzer ignores the person
    /// box (treats it as nil) — bad person boxes mislead fish/person ratios
    /// in both the heuristic and the regressor's feature vector.
    public var personDetectMinConfidence: Float {
        if let v = overridePersonDetectMinConfidence { return Float(v) }
        if let s = stringFromInfo("PERSON_DETECT_MIN_CONFIDENCE"), let v = Float(s) { return v }
        return 0.40
    }

    /// Strength of the diagonal-fraction correction in the heuristic length
    /// estimator. Adjusts raw pixel-length by `(1 + strength × (0.5 - diagFrac))`:
    /// tight close-ups (high diagFrac) bias the estimate down, wide shots bias
    /// it up. Set 0 to disable. Reasonable range 0.3–0.8.
    public var heuristicDiagFracStrength: Float {
        if let v = overrideHeuristicDiagFracStrength { return Float(v) }
        if let s = stringFromInfo("HEURISTIC_DIAG_FRAC_STRENGTH"), let v = Float(s) { return v }
        return 0.6
    }

    /// Scale factor applied to bounding box length (compensates for oversized training boxes).
    public var fishBoxScaleFactor: CGFloat {
        if let v = overrideFishBoxScaleFactor { return CGFloat(v) }
        if let s = stringFromInfo("FISH_BOX_SCALE_FACTOR"), let v = Double(s) { return CGFloat(v) }
        return 0.59
    }

    /// Calibration constant: pixels per inch in the 640×640 model space.
    public var fishPixelsPerInch: CGFloat {
        if let v = overrideFishPixelsPerInch { return CGFloat(v) }
        if let s = stringFromInfo("FISH_PIXELS_PER_INCH"), let v = Double(s) { return CGFloat(v) }
        return 11.7
    }

    /// Minimum plausible fish length in inches (clamp floor).
    public var fishMinLengthInches: Double {
        if let v = overrideFishMinLengthInches { return v }
        if let s = stringFromInfo("FISH_MIN_LENGTH_INCHES"), let v = Double(s) { return v }
        return 10.0
    }

    /// Maximum plausible fish length in inches (clamp ceiling).
    public var fishMaxLengthInches: Double {
        if let v = overrideFishMaxLengthInches { return v }
        if let s = stringFromInfo("FISH_MAX_LENGTH_INCHES"), let v = Double(s) { return v }
        return 47.0
    }

    /// Low-end multiplier for the length estimate range.
    public var fishEstimateLowFactor: Double {
        if let v = overrideFishEstimateLowFactor { return v }
        if let s = stringFromInfo("FISH_ESTIMATE_LOW_FACTOR"), let v = Double(s) { return v }
        return 0.93
    }

    /// High-end multiplier for the length estimate range.
    public var fishEstimateHighFactor: Double {
        if let v = overrideFishEstimateHighFactor { return v }
        if let s = stringFromInfo("FISH_ESTIMATE_HIGH_FACTOR"), let v = Double(s) { return v }
        return 1.07
    }

    /// Whether to use the ML length regressor instead of the heuristic.
    /// Defaults to true. Set to false to fall back to pixel-based heuristic.
    public var useLengthRegressor: Bool {
        if let v = overrideUseLengthRegressor { return v }
        if let s = stringFromInfo("USE_LENGTH_REGRESSOR") { return s.lowercased() == "true" }
        return true
    }

    /// Minimum ViT softmax confidence (0.0–1.0) required to report a species.
    /// Below this threshold the analyzer returns "Species not detected".
    public var speciesDetectionThreshold: Float {
        if let v = overrideSpeciesDetectionThreshold { return Float(v) }
        if let s = stringFromInfo("SPECIES_DETECTION_THRESHOLD"), let v = Float(s) { return v }
        return 0.70
    }

    /// When the ViT top-1 softmax probability falls below this threshold, the chat
    /// flow surfaces up to 2 species options as tappable capsules (primary + runner-up)
    /// instead of silently committing to the winner. Helps catch ambiguous cases
    /// like 0.7 sea_run_trout / 0.23 chinook_salmon before the model's overconfidence
    /// locks in a wrong answer.
    public var speciesRunnerUpTrigger: Float {
        if let s = stringFromInfo("SPECIES_RUNNER_UP_TRIGGER"), let v = Float(s) { return v }
        return 0.85
    }

    /// Minimum softmax probability a runner-up species must exceed to appear as a
    /// capsule. Filters out noise — anything below this is statistical background
    /// for a 4-6 class classifier.
    public var speciesRunnerUpMinProb: Float {
        if let s = stringFromInfo("SPECIES_RUNNER_UP_MIN_PROB"), let v = Float(s) { return v }
        return 0.15
    }

}
