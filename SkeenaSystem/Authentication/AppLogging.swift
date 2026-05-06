// AppLogging.swift
import Foundation
import os

public enum LogLevel: Int {
  case debug = 0
  case info
  case warn
  case error
}

public enum LogCategory: String, CaseIterable, Hashable {
  case auth = "auth"
  case network = "network"
  case trip = "trip"
  case ui = "ui"
  case `catch` = "catch"           // catch-related flows (photo capture, analysis results)
  case ml = "ml"                   // Core ML / Vision inference pipelines
  case persistence = "persistence" // Core Data and other storage
  case audio = "audio"             // Voice memo / audio processing
  case angler = "angler"
  case location = "location"       // GPS, water body lookup, coordinate matching
  case upload = "upload"           // Upload orchestration & phase transitions
  case weather = "weather"         // Forecast requests & data sourcing
  case observation = "observation" // Observation capture, storage, upload
  case community = "community"     // Community switching, member management
  case map = "map"                 // Map rendering, report clustering, callouts
  case research = "research"       // Researcher role workflows & catch confirmation
}

public nonisolated struct AppLogging {
  // Global master switch.
  // nonisolated(unsafe) — set at boot, mutated only by tests; the unsynchronized
  // window is acceptable for a logging toggle (a torn read at worst skips one
  // log line). Same goes for `enabledCategories` and `minimumLevel` below.
  public nonisolated(unsafe) static var enabled: Bool = true

  // Per-category switches. Resolved from Info.plist "LOG_CATEGORIES" (comma-separated
  // category names, e.g. "ml,catch,angler"). Empty/missing = all categories enabled.
  public nonisolated(unsafe) static var enabledCategories: Set<LogCategory> = resolveCategoriesFromInfoPlist()

  // Resolve minimum log level from Info.plist keys: prefers "LOG_LEVEL", falls back to "Log Level".
  private static func resolveMinimumLevelFromInfoPlist() -> LogLevel {
    func read(_ key: String) -> String? {
      (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let raw = (read("LOG_LEVEL") ?? read("Log Level") ?? "").lowercased()
    switch raw {
    case "error": return .error
    case "warn", "warning": return .warn
    case "info": return .info
    case "debug": return .debug
    default:
      return .debug
    }
  }

  /// Parse a comma-separated category list. Empty/whitespace-only yields all categories.
  /// Unknown tokens are ignored. Matching is case-insensitive against `LogCategory.rawValue`.
  /// If every token is unknown, falls back to all categories so logging isn't silently disabled.
  static func parseCategories(_ raw: String) -> Set<LogCategory> {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return Set(LogCategory.allCases) }

    let tokens = trimmed.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespaces).lowercased()
    }
    let resolved = tokens.compactMap { LogCategory(rawValue: $0) }
    return resolved.isEmpty ? Set(LogCategory.allCases) : Set(resolved)
  }

  private static func resolveCategoriesFromInfoPlist() -> Set<LogCategory> {
    let raw = (Bundle.main.object(forInfoDictionaryKey: "LOG_CATEGORIES") as? String) ?? ""
    return parseCategories(raw)
  }

  public nonisolated(unsafe) static var minimumLevel: LogLevel = resolveMinimumLevelFromInfoPlist()

  // Subsystem should be your bundle identifier; fallback to a generic string if not available
  private static let subsystem: String = {
    if let id = Bundle.main.bundleIdentifier { return id }
    return "com.epicwaters.app"
  }()

  // Category-specific os.Logger instances
  private static let authLogger = Logger(subsystem: subsystem, category: LogCategory.auth.rawValue)
  private static let networkLogger = Logger(subsystem: subsystem, category: LogCategory.network.rawValue)
  private static let tripLogger = Logger(subsystem: subsystem, category: LogCategory.trip.rawValue)
  private static let uiLogger = Logger(subsystem: subsystem, category: LogCategory.ui.rawValue)
  private static let catchLogger = Logger(subsystem: subsystem, category: LogCategory.catch.rawValue)
  private static let mlLogger = Logger(subsystem: subsystem, category: LogCategory.ml.rawValue)
  private static let persistenceLogger = Logger(subsystem: subsystem, category: LogCategory.persistence.rawValue)
  private static let audioLogger = Logger(subsystem: subsystem, category: LogCategory.audio.rawValue)
  private static let anglerLogger = Logger(subsystem: subsystem, category: LogCategory.angler.rawValue)
  private static let locationLogger = Logger(subsystem: subsystem, category: LogCategory.location.rawValue)
  private static let uploadLogger = Logger(subsystem: subsystem, category: LogCategory.upload.rawValue)
  private static let weatherLogger = Logger(subsystem: subsystem, category: LogCategory.weather.rawValue)
  private static let observationLogger = Logger(subsystem: subsystem, category: LogCategory.observation.rawValue)
  private static let communityLogger = Logger(subsystem: subsystem, category: LogCategory.community.rawValue)
  private static let mapLogger = Logger(subsystem: subsystem, category: LogCategory.map.rawValue)
  private static let researchLogger = Logger(subsystem: subsystem, category: LogCategory.research.rawValue)

  // One-time diagnostic: log resolved LOG_LEVEL using os.Logger directly (unfiltered)
  private static let __logLevelDiagnostic: Void = {
    let raw = (Bundle.main.object(forInfoDictionaryKey: "LOG_LEVEL") as? String) ??
              (Bundle.main.object(forInfoDictionaryKey: "Log Level") as? String) ?? "<missing>"
    let logger = Logger(subsystem: subsystem, category: "system")
    logger.error("Resolved LOG_LEVEL (Info.plist): \(raw, privacy: .public). Effective minimum: \(String(describing: minimumLevel), privacy: .public)")
    let rawCats = (Bundle.main.object(forInfoDictionaryKey: "LOG_CATEGORIES") as? String) ?? "<missing>"
    let effectiveCats = enabledCategories.map { $0.rawValue }.sorted().joined(separator: ",")
    logger.error("Resolved LOG_CATEGORIES (Info.plist): \(rawCats, privacy: .public). Effective: \(effectiveCats, privacy: .public)")
  }()

  // Primary logging API
  public static func log(_ message: () -> String,
                         level: LogLevel = .debug,
                         category: LogCategory = .ui) {
    _ = __logLevelDiagnostic
    guard enabled else { return }
    guard enabledCategories.contains(category) else { return }
    guard level.rawValue >= minimumLevel.rawValue else { return }

    let msg = message()

    let logger: Logger = {
      switch category {
      case .auth: return authLogger
      case .network: return networkLogger
      case .trip: return tripLogger
      case .ui: return uiLogger
      case .catch: return catchLogger
      case .ml: return mlLogger
      case .persistence: return persistenceLogger
      case .audio: return audioLogger
      case .angler: return anglerLogger
      case .location: return locationLogger
      case .upload: return uploadLogger
      case .weather: return weatherLogger
      case .observation: return observationLogger
      case .community: return communityLogger
      case .map: return mapLogger
      case .research: return researchLogger
      }
    }()

    switch level {
    case .debug:
      logger.debug("\(msg)")
    case .info:
      logger.info("\(msg)")
    case .warn:
      logger.warning("\(msg)")
    case .error:
      logger.error("\(msg)")
    }
  }

  public static func log(_ message: String,
                         level: LogLevel = .debug,
                         category: LogCategory = .ui) {
    log({ message }, level: level, category: category)
  }
}
