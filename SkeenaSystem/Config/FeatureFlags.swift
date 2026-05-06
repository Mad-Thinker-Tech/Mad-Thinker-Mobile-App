// Bend Fly Shop
// FeatureFlags.swift
//
// Reads a Bool entitlement from Info.plist (populated via xcconfig).
// Returns false when the key is absent or cannot be parsed.

import Foundation

nonisolated func readEntitlement(_ key: String) -> Bool {
  if let value = Bundle.main.object(forInfoDictionaryKey: key) {
    if let boolValue = value as? Bool { return boolValue }
    if let stringValue = value as? String { return (stringValue as NSString).boolValue }
    if let numberValue = value as? NSNumber { return numberValue.boolValue }
  }
  return false
}
