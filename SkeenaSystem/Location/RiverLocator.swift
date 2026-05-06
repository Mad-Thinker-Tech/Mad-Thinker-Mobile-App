//
//  RiverLocator.swift
//  SkeenaSystem
//
//  Dynamically builds its river dataset from RiverAtlas, filtered by
//  the community's LODGE_RIVERS configuration. No hardcoded river lists.
//

import Foundation
import CoreLocation

/// Represents a fishable river entry in our offline dataset.
///
/// Note: `coordinates` is a "spine" of points along the river.
/// We'll treat the river's coverage as the union of circles
/// around each of these points, with radius `maxDistanceKm`.
nonisolated struct RiverDefinition: Sendable {
  let name: String
  let communityID: String
  let coordinates: [CLLocationCoordinate2D]
  let maxDistanceKm: Double      // max distance from ANY point to count as on this river

  /// The river's base name with water-body suffixes stripped
  /// (e.g. "Nehalem River" → "Nehalem", "Kilchis River" → "Kilchis").
  var shortName: String {
    let suffixes = [" Creek", " River", " Lake", " Stream"]
    for suffix in suffixes where name.hasSuffix(suffix) {
      return String(name.dropLast(suffix.count))
    }
    return name
  }
}

/// Main entry point for river lookup. Designed to be community- and dataset-agnostic.
///
/// The river dataset is built dynamically from `RiverAtlas.all`, filtered to only
/// include rivers listed in `AppEnvironment.shared.lodgeRivers`. This means:
/// - `RiverCoordinates.swift` is a cumulative atlas (add rivers, never remove)
/// - `LODGE_RIVERS` in xcconfig controls which rivers are active per community
/// - No code changes needed in this file when onboarding a new community
/// `nonisolated` so the upload pipeline (which runs off MainActor) can call
/// `riverName(near:)` synchronously. Reads `CommunityService` via the
/// `*Snapshot` accessors, which are backed by a Sendable `CurrentValueSubject`.
nonisolated final class RiverLocator: @unchecked Sendable {

  static let shared = RiverLocator()

  // MARK: - Dataset (built dynamically from atlas + active community config)

  /// Cached rivers for the current community. Rebuilt when the community
  /// changes (keyed off `activeCommunityIdSnapshot`).
  /// `nonisolated(unsafe)` because the only writer is the lazy getter below;
  /// upload code is the only off-main caller and serializes its requests.
  nonisolated(unsafe) private var _cachedRivers: [RiverDefinition] = []
  nonisolated(unsafe) private var _cachedCommunityId: String = ""

  private var rivers: [RiverDefinition] {
    // Cache key: active community id. Switching communities invalidates
    // the cached rivers automatically. Empty id means no community is
    // selected — return empty so callers see "no match" rather than
    // stale cached rivers from a previous community.
    let communityId = CommunityService.shared.activeCommunityIdSnapshot ?? ""
    if communityId == _cachedCommunityId, !_cachedRivers.isEmpty {
      return _cachedRivers
    }
    _cachedCommunityId = communityId
    let configuredRivers = CommunityService.shared.activeCommunityConfigSnapshot.resolvedLodgeRivers
    _cachedRivers = configuredRivers.compactMap { riverName in
      let coords = RiverAtlas.all[riverName]
        ?? RiverAtlas.all[riverName + " River"]
        ?? RiverAtlas.all[riverName + " Creek"]
        ?? RiverAtlas.all[riverName + " Lake"]
        ?? RiverAtlas.all[riverName + " Stream"]
      guard let coords, !coords.isEmpty else {
        // Surface the silent-drop case: a community configured a river
        // name the atlas doesn't know about. Without this log, mismatches
        // like "Klamath River (California)" vs "Klamath River" cause
        // river resolution to silently return nil with no trace.
        AppLogging.log("[RiverLocator] No atlas entry for configured river '\(riverName)' (communityId=\(communityId))", level: .warn, category: .catch)
        return nil
      }
      return RiverDefinition(
        name: riverName,
        communityID: communityId,
        coordinates: coords,
        maxDistanceKm: RiverAtlas.defaultMaxDistanceKm
      )
    }
    return _cachedRivers
  }

  private init() {}

  // MARK: - Public API

  /// Returns the best-matching river and its distance for this location.
  ///
  /// Semantics:
  /// - If `location` is nil → nil
  /// - For each loaded river, compute the minimum distance to ANY spine point.
  /// - If that distance ≤ `maxDistanceKm`, the river is a candidate.
  /// - Return the candidate with the smallest distance.
  func riverMatch(near location: CLLocation?) -> (name: String, distanceKm: Double)? {
    guard let location else { return nil }
    guard !rivers.isEmpty else { return nil }

    var bestRiver: RiverDefinition?
    var bestDistanceKm = Double.greatestFiniteMagnitude

    for river in rivers {
      guard !river.coordinates.isEmpty else { continue }

      var bestDistanceForRiver = Double.greatestFiniteMagnitude

      for coord in river.coordinates {
        let riverLoc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let distanceKm = location.distance(from: riverLoc) / 1000.0

        if distanceKm < bestDistanceForRiver {
          bestDistanceForRiver = distanceKm
        }
      }

      guard bestDistanceForRiver <= river.maxDistanceKm else { continue }

      if bestDistanceForRiver < bestDistanceKm {
        bestDistanceKm = bestDistanceForRiver
        bestRiver = river
      }
    }

    guard let best = bestRiver else { return nil }
    return (name: best.shortName, distanceKm: bestDistanceKm)
  }

  /// Convenience: returns just the river name (empty string if no match).
  func riverName(near location: CLLocation?) -> String {
    riverMatch(near: location)?.name ?? ""
  }
}
