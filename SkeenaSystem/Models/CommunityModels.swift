//
//  CommunityModels.swift
//  SkeenaSystem
//
//  Models for the multi-tenant community system.
//  Communities are a first-class entity with UUID ids and 6-char codes.
//  Users belong to communities via user_communities junction table.
//

import Foundation

// MARK: - Community membership (from user_communities + communities join)

struct CommunityMembership: Codable, Identifiable {
    let id: String
    let communityId: String
    let role: String  // "guide", "angler", or "public"
    let isActive: Bool
    let communities: CommunityInfo

    enum CodingKeys: String, CodingKey {
        case id
        case communityId = "community_id"
        case role
        case isActive = "is_active"
        case communities
    }
}

struct CommunityInfo: Codable, Identifiable {
    let id: String
    let name: String
    let code: String
    let isActive: Bool
    let communityTypeId: String?

    // Branding (from communities table columns)
    let logoUrl: String?
    let logoAssetName: String?
    let tagline: String?
    let displayName: String?
    let learnUrl: String?
    let customUrls: [CustomURL]?
    let donationUrl: String?
    let donationDescription: String?

    // Geography (JSONB from communities table)
    let geography: CommunityGeography?

    // Unit system: "metric" or "imperial" (defaults to "metric" if absent)
    let units: String?

    // Nested join to community_types (singular — 1:1 via community_type_id FK)
    let communityTypes: CommunityTypeInfo?

    enum CodingKeys: String, CodingKey {
        case id, name, code
        case isActive = "is_active"
        case communityTypeId = "community_type_id"
        case logoUrl = "logo_url"
        case logoAssetName = "logo_asset_name"
        case tagline
        case displayName = "display_name"
        case learnUrl = "learn_url"
        case customUrls = "custom_urls"
        case donationUrl = "donation_url"
        case donationDescription = "donation_description"
        case geography
        case units
        case communityTypes = "community_types"
    }

    /// Merges branding, geography (community-level), and entitlements (type-level)
    /// into a unified CommunityConfig for the app to consume.
    var config: CommunityConfig {
        CommunityConfig(
            logoUrl: logoUrl,
            logoAssetName: logoAssetName,
            tagline: tagline,
            displayName: displayName,
            learnUrl: learnUrl,
            customUrls: customUrls,
            donationUrl: donationUrl,
            donationDescription: donationDescription,
            entitlements: communityTypes?.entitlements ?? [:],
            geography: geography ?? .empty,
            units: units
        )
    }
}

// MARK: - Custom URL (from communities.custom_urls JSONB)

/// Named link configured per community. Up to 5 entries; backend validates
/// non-empty name (≤100 chars) and url (≤2048 chars). Replaces the legacy
/// single `learn_url` field — see api-reference.md.
nonisolated struct CustomURL: Codable, Equatable, Hashable, Identifiable, Sendable {
    let name: String
    let url: String

    var id: String { url }
}

// MARK: - Community type (from community_types table)

struct CommunityTypeInfo: Codable, Identifiable {
    let id: String
    let name: String  // "Lodge", "FlyShop", "Conservation", "MultiLodge"
    let entitlements: [String: Bool]

    enum CodingKeys: String, CodingKey {
        case id, name
        case entitlements
    }
}

// MARK: - Community geography (JSONB from communities.geography)

nonisolated struct CommunityGeography: Codable, Equatable, Sendable {
    let defaultRiver: String?
    let lodgeRivers: [String]?
    let defaultWaterBody: String?
    let lodgeWaterBodies: [String]?
    let forecastLocation: String?
    let defaultMapLatitude: Double?
    let defaultMapLongitude: Double?

    enum CodingKeys: String, CodingKey {
        case defaultRiver = "default_river"
        case lodgeRivers = "lodge_rivers"
        case defaultWaterBody = "default_water_body"
        case lodgeWaterBodies = "lodge_water_bodies"
        case forecastLocation = "forecast_location"
        case defaultMapLatitude = "default_map_latitude"
        case defaultMapLongitude = "default_map_longitude"
    }

    static let empty = CommunityGeography(
        defaultRiver: nil, lodgeRivers: nil, defaultWaterBody: nil,
        lodgeWaterBodies: nil, forecastLocation: nil,
        defaultMapLatitude: nil, defaultMapLongitude: nil
    )
}

// MARK: - Join community API response

struct JoinCommunityResponse: Codable {
    let success: Bool?
    let communityName: String?
    let communityId: String?
    let communityType: String?
    let role: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case success
        case communityName = "community_name"
        case communityId = "community_id"
        case communityType = "community_type"
        case role
        case error
    }
}
