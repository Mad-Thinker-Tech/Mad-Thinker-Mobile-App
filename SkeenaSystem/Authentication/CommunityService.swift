//
//  CommunityService.swift
//  SkeenaSystem
//
//  Manages community memberships and active community context.
//  After login, fetches user_communities to determine which communities
//  the user belongs to and their role in each.
//

import Foundation
import Combine

final class CommunityService: ObservableObject {
    nonisolated static let shared = CommunityService()

    // MARK: - Published state

    @Published private(set) var memberships: [CommunityMembership] = []
    @Published var activeCommunityId: String? {
        didSet { _activeCommunityIdSubject.send(activeCommunityId) }
    }
    @Published private(set) var activeRole: String?  // "guide", "angler", or "public"
    @Published private(set) var activeCommunityTypeId: String?
    @Published private(set) var activeCommunityTypeName: String?
    @Published private(set) var activeCommunityConfig: CommunityConfig = .default {
        didSet { _activeCommunityConfigSubject.send(activeCommunityConfig) }
    }

    // Nonisolated mirrors of the @Published values above. Used by upload code
    // and the locators (RiverLocator, WaterBodyLocator), which run off
    // MainActor for the iOS 26.2 deinit-crash mitigation. CurrentValueSubject
    // is Sendable; reads from any thread observe a coherent snapshot of
    // whatever value the @Published last published.
    nonisolated private let _activeCommunityIdSubject = CurrentValueSubject<String?, Never>(nil)
    nonisolated private let _activeCommunityConfigSubject = CurrentValueSubject<CommunityConfig, Never>(.default)
    nonisolated var activeCommunityIdSnapshot: String? { _activeCommunityIdSubject.value }
    nonisolated var activeCommunityConfigSnapshot: CommunityConfig { _activeCommunityConfigSubject.value }
    nonisolated var activeCommunityIdPublisher: AnyPublisher<String?, Never> { _activeCommunityIdSubject.eraseToAnyPublisher() }
    /// The user's chosen default community. Survives logout so subsequent logins
    /// auto-select this community and skip the picker. Cleared only when the user
    /// explicitly changes it or is no longer a member.
    @Published var defaultCommunityId: String?
    /// True after fetchMemberships() completes (success or failure). Views should
    /// wait for this before rendering community-dependent content.
    @Published private(set) var hasFetchedMemberships = false

    /// Whether the current user's membership in the active community is active.
    /// False means the member has been deactivated by a guide/admin.
    @Published private(set) var isMemberActive: Bool = true

    /// Per-community add-on flags fetched from the `community_addons` table.
    /// Keyed by addon_name (e.g. "Social"), value is `is_active`.
    @Published private(set) var addons: [String: Bool] = [:]

    /// Whether the Social add-on is active for the current community.
    var isSocialActive: Bool { addons["Social"] ?? false }

    /// Whether the active community is a Conservation-type community.
    /// Used to gate researcher-specific views and features.
    var isConservation: Bool { activeCommunityTypeName == "Conservation" }

    // MARK: - Persistence keys

    private let kActiveCommunityId = "CommunityService.activeCommunityId"
    private let kActiveRole = "CommunityService.activeRole"
    private let kActiveCommunityTypeId = "CommunityService.activeCommunityTypeId"
    private let kActiveCommunityTypeName = "CommunityService.activeCommunityTypeName"
    private let kActiveCommunityConfig = "CommunityService.activeCommunityConfig"
    private let kDefaultCommunityId = "CommunityService.defaultCommunityId"

    /// Per-user cached memberships list. Keyed by `<prefix>+<memberId>` so two
    /// users on the same device don't see each other's communities. Mirrors
    /// the per-member directory scoping used by `CatchReportStore`.
    private static let kCachedMembershipsPrefix = "CommunityService.cachedMemberships."

    // MARK: - Config (lazy to avoid Info.plist crash in test targets)

    private var projectURL: URL { AppEnvironment.shared.projectURL }
    private var anonKey: String { AppEnvironment.shared.anonKey }

    private init() {
        // Restore cached active community on launch
        activeCommunityId = UserDefaults.standard.string(forKey: kActiveCommunityId)
        activeRole = UserDefaults.standard.string(forKey: kActiveRole)
        activeCommunityTypeId = UserDefaults.standard.string(forKey: kActiveCommunityTypeId)
        activeCommunityTypeName = UserDefaults.standard.string(forKey: kActiveCommunityTypeName)
        defaultCommunityId = UserDefaults.standard.string(forKey: kDefaultCommunityId)

        // Restore cached community config for instant cold-launch rendering
        if let configData = UserDefaults.standard.data(forKey: kActiveCommunityConfig),
           let cached = try? JSONDecoder().decode(CommunityConfig.self, from: configData) {
            activeCommunityConfig = cached
        }

        // Restore cached memberships list keyed by the user's memberId so the
        // community picker is populated on offline cold launch. Reads from the
        // static AuthService cache to avoid any ordering dependency on AuthService init.
        let cachedMemberId = AuthService.loadCachedAuthState().memberId
        let restored = Self.loadCachedMemberships(for: cachedMemberId)
        if !restored.isEmpty {
            memberships = restored
            AppLogging.log("[CommunityService] Restored \(restored.count) cached membership(s) for memberId=\(cachedMemberId ?? "<nil>")", level: .debug, category: .community)
        }

        if let cachedId = activeCommunityId {
            AppLogging.log("[CommunityService] Restored cached community: id=\(cachedId) role=\(activeRole ?? "nil") typeId=\(activeCommunityTypeId ?? "nil") flags=\(activeCommunityConfig.entitlements.count)", level: .debug, category: .community)
        }
    }

    // MARK: - Computed properties

    var activeCommunityName: String {
        guard let activeId = activeCommunityId,
              let membership = memberships.first(where: { $0.communityId == activeId }) else {
            return AppEnvironment.shared.communityName
        }
        return membership.communities.name
    }

    var activeMembership: CommunityMembership? {
        guard let activeId = activeCommunityId else { return nil }
        return memberships.first(where: { $0.communityId == activeId })
    }

    var hasMultipleCommunities: Bool {
        memberships.count > 1
    }

    // MARK: - Fetch memberships

    /// Fetches user_communities with joined community info from the REST API.
    /// Call after successful login/token refresh.
    func fetchMemberships() async {
        // --- DIAGNOSTIC: Log pre-fetch state ---
        AppLogging.log("[CommunityService][DIAG] Pre-fetch state: memberships.count=\(memberships.count) activeCommunityId=\(activeCommunityId ?? "nil") hasFetched=\(hasFetchedMemberships)", level: .info, category: .community)
        if let cachedConfigData = UserDefaults.standard.data(forKey: kActiveCommunityConfig) {
            AppLogging.log("[CommunityService][DIAG] Cached config in UserDefaults: \(cachedConfigData.count) bytes", level: .debug, category: .community)
        } else {
            AppLogging.log("[CommunityService][DIAG] No cached config in UserDefaults", level: .debug, category: .community)
        }
        AppLogging.log("[CommunityService][DIAG] Cached activeCommunityId in UserDefaults: \(UserDefaults.standard.string(forKey: kActiveCommunityId) ?? "nil")", level: .debug, category: .community)

        guard let token = await AuthService.shared.currentAccessToken() else {
            AppLogging.log("[CommunityService] No access token for membership fetch", level: .warn, category: .community)
            await hydrateFromCacheAndMarkFetched(reason: "no token")
            return
        }

        // Offline-with-valid-token: cached JWT can stay valid up to ~58 min after
        // going offline. Without this guard the launch path makes a real GET that
        // hangs on URLSession's ~60s default timeout, leaving AppRootView stuck on
        // the loading spinner. Cache fallback is the same one used in the no-token
        // branch above.
        if !NetworkMonitor.shared.isOnlineSnapshot {
            await hydrateFromCacheAndMarkFetched(reason: "offline with valid token")
            return
        }

        // --- DIAGNOSTIC: Decode JWT subject (user ID) to verify we're using the right token ---
        if let payload = token.split(separator: ".").dropFirst().first,
           let padded = Data(base64Encoded: String(payload).padding(toLength: ((payload.count + 3) / 4) * 4, withPad: "=", startingAt: 0)),
           let json = try? JSONSerialization.jsonObject(with: padded) as? [String: Any] {
            let sub = json["sub"] as? String ?? "unknown"
            let exp = json["exp"] as? Int ?? 0
            AppLogging.log("[CommunityService][DIAG] JWT sub (user_id)=\(sub) exp=\(exp)", level: .info, category: .community)
        }

        // Build URL: GET /rest/v1/user_communities with nested joins for branding, geography + entitlements
        // `left_at=is.null` excludes rows soft-deleted by /functions/v1/leave-community
        // so a community the user has left never reappears in the picker. Defensive
        // even if backend RLS already filters these — PostgREST silently no-ops the
        // filter when no matching rows exist.
        var comps = URLComponents(url: projectURL.appendingPathComponent("/rest/v1/user_communities"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "select", value: "id,community_id,role,is_active,communities(id,name,code,is_active,community_type_id,logo_url,logo_asset_name,tagline,display_name,learn_url,custom_urls,donation_url,donation_description,geography,units,community_types(id,name,entitlements))"),
            URLQueryItem(name: "left_at", value: "is.null")
        ]

        var request = URLRequest(url: comps.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        // Bound the launch path: belt-and-braces backstop for the NetworkMonitor
        // startup race and half-connected Wi-Fi (lodge captive portals).
        request.timeoutInterval = 8

        AppLogging.log("[CommunityService][DIAG] Fetching: \(comps.url?.absoluteString ?? "nil")", level: .debug, category: .community)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

            // --- DIAGNOSTIC: Log raw response ---
            let rawBody = String(data: data, encoding: .utf8) ?? "<non-UTF8>"
            AppLogging.log("[CommunityService][DIAG] Response status=\(statusCode) body=\(rawBody)", level: .info, category: .community)

            guard (200..<300).contains(statusCode) else {
                AppLogging.log("[CommunityService] Fetch failed status=\(statusCode) body=\(rawBody)", level: .error, category: .community)
                await MainActor.run { self.hasFetchedMemberships = true }
                return
            }

            let decoder = JSONDecoder()
            let allFetched = try decoder.decode([CommunityMembership].self, from: data)
            // Filter out inactive communities — they should not be selectable or displayed
            let fetched = allFetched.filter { $0.communities.isActive }
            if allFetched.count != fetched.count {
                let inactiveNames = allFetched.filter { !$0.communities.isActive }.map { $0.communities.name }
                AppLogging.log("[CommunityService] Filtered \(allFetched.count - fetched.count) inactive community(s): \(inactiveNames.joined(separator: ", "))", level: .info, category: .community)
            }

            await MainActor.run {
                self.memberships = fetched
                self.persistMemberships(fetched)
                AppLogging.log("[CommunityService] Fetched \(fetched.count) active membership(s) from server", level: .info, category: .community)
                for m in fetched {
                    let typeName = m.communities.communityTypes?.name ?? "nil"
                    let flagCount = m.communities.communityTypes?.entitlements.count ?? 0
                    let customUrls = m.communities.customUrls ?? []
                    AppLogging.log("[CommunityService]   • \(m.communities.name) role=\(m.role) type=\(typeName) flags=\(flagCount) logo=\(m.communities.logoUrl ?? "bundled") custom_urls=\(customUrls.count)", level: .debug, category: .community)
                    for (idx, link) in customUrls.enumerated() {
                        AppLogging.log("[CommunityService]       custom_urls[\(idx)] name=\(link.name) url=\(link.url)", level: .debug, category: .community)
                    }
                }

                // Validate cached selection or leave nil so picker is shown
                if let cachedId = self.activeCommunityId {
                    // Validate the cached selection still exists
                    if fetched.contains(where: { $0.communityId == cachedId }) {
                        // Refresh role, type, and config in case they changed
                        if let membership = fetched.first(where: { $0.communityId == cachedId }) {
                            self.activeRole = membership.role
                            self.activeCommunityTypeId = membership.communities.communityTypeId
                            self.activeCommunityTypeName = membership.communities.communityTypes?.name
                            self.activeCommunityConfig = membership.communities.config
                            self.isMemberActive = membership.isActive
                            persistActiveState()

                            // Sync role to AuthService so AppRootView routes to the correct landing view
                            if let userType = AuthService.UserType(rawValue: membership.role) {
                                AuthService.shared.updateUserType(userType)
                            }

                            let typeName = membership.communities.communityTypes?.name ?? "nil"
                            AppLogging.log("[CommunityService] Refreshed cached community: id=\(cachedId) role=\(membership.role) type=\(typeName) memberActive=\(membership.isActive) flags=\(self.activeCommunityConfig.entitlements.count)", level: .debug, category: .community)
                        }
                    } else {
                        // Cached community no longer valid — clear selection so picker is shown
                        self.activeCommunityId = nil
                        self.activeRole = nil
                        self.activeCommunityTypeId = nil
                        self.activeCommunityTypeName = nil
                        self.activeCommunityConfig = .default
                        persistActiveState()
                        AppLogging.log("[CommunityService] Cached community no longer valid — showing picker for \(fetched.count) communities", level: .info, category: .community)
                    }
                } else if let defaultId = self.defaultCommunityId,
                          fetched.contains(where: { $0.communityId == defaultId }) {
                    // No active selection but user has a valid default — auto-select it
                    AppLogging.log("[CommunityService] Auto-selecting default community: id=\(defaultId)", level: .info, category: .community)
                    self.setActiveCommunity(id: defaultId)
                } else if fetched.count == 1, let only = fetched.first {
                    // Single community — auto-select and skip the picker
                    AppLogging.log("[CommunityService] Single community — auto-selecting: \(only.communities.name) role=\(only.role)", level: .info, category: .community)
                    self.setActiveCommunity(id: only.communityId)
                    self.setDefaultCommunity(id: only.communityId)
                } else {
                    // No cached selection and no valid default — show picker
                    if let defaultId = self.defaultCommunityId {
                        // Default exists but user is no longer a member — clear it
                        AppLogging.log("[CommunityService] Default community \(defaultId) no longer valid — clearing", level: .info, category: .community)
                        self.clearDefaultCommunity()
                    }
                    AppLogging.log("[CommunityService] No cached selection — \(fetched.count) communities available, showing picker", level: .info, category: .community)
                }

                self.hasFetchedMemberships = true
            }
        } catch {
            AppLogging.log("[CommunityService] Fetch error: \(error)", level: .error, category: .community)
            await MainActor.run { self.hasFetchedMemberships = true }
        }
    }

    // MARK: - Set active community

    func setActiveCommunity(id: String) {
        activeCommunityId = id
        let membership = memberships.first(where: { $0.communityId == id })
        activeRole = membership?.role
        activeCommunityTypeId = membership?.communities.communityTypeId
        activeCommunityTypeName = membership?.communities.communityTypes?.name
        activeCommunityConfig = membership?.communities.config ?? .default
        isMemberActive = membership?.isActive ?? true
        persistActiveState()

        // Sync role to AuthService synchronously so existing views that read
        // auth.currentUserType see the correct value on the same render pass.
        // Previously this was wrapped in Task { @MainActor in ... }, which
        // deferred the update and caused AppRootView to briefly render
        // GuideLandingView (the default branch) for non-guide roles before
        // swapping. setActiveCommunity is always called on the main actor
        // (SwiftUI view taps and the fetchMemberships MainActor.run block),
        // so a direct call is safe.
        if let role = activeRole, let userType = AuthService.UserType(rawValue: role) {
            AuthService.shared.updateUserType(userType)
        }

        let typeName = membership?.communities.communityTypes?.name ?? "nil"
        let customUrlCount = activeCommunityConfig.resolvedCustomUrls.count
        let donationStatus = activeCommunityConfig.resolvedDonation == nil ? "absent" : "present"
        AppLogging.log("[CommunityService] Active community set: id=\(id) role=\(activeRole ?? "nil") type=\(typeName) memberActive=\(isMemberActive) flags=\(activeCommunityConfig.entitlements.count) logo=\(activeCommunityConfig.logoUrl ?? "bundled") custom_urls=\(customUrlCount) donation=\(donationStatus) name=\(activeCommunityName)", level: .info, category: .community)
        for (idx, link) in activeCommunityConfig.resolvedCustomUrls.enumerated() {
            AppLogging.log("[CommunityService]   custom_urls[\(idx)] name=\(link.name) url=\(link.url)", level: .info, category: .community)
        }

        // Fetch add-ons for the newly active community
        Task { await fetchAddons() }
    }

    // MARK: - Default community

    /// Designate a community as the user's default. Persists across logouts so
    /// subsequent logins auto-select this community and skip the picker.
    func setDefaultCommunity(id: String) {
        defaultCommunityId = id
        UserDefaults.standard.set(id, forKey: kDefaultCommunityId)
        AppLogging.log("[CommunityService] Default community set: id=\(id)", level: .info, category: .community)
    }

    /// Remove the default community designation. The picker will be shown on next login.
    func clearDefaultCommunity() {
        defaultCommunityId = nil
        UserDefaults.standard.removeObject(forKey: kDefaultCommunityId)
        AppLogging.log("[CommunityService] Default community cleared", level: .info, category: .community)
    }

    /// Nils the active community (routing back to the picker) without a full logout.
    /// Used when the user wants to update their default community from the switcher.
    func clearActiveCommunity() {
        activeCommunityId = nil
        activeRole = nil
        activeCommunityTypeId = nil
        activeCommunityTypeName = nil
        activeCommunityConfig = .default
        isMemberActive = true
        addons = [:]
        persistActiveState()
        AppLogging.log("[CommunityService] Active community cleared — showing picker", level: .info, category: .community)
    }

    // MARK: - Join community

    /// Join a new community using a 6-char code and the member number from the invite email.
    /// POST /functions/v1/join-community
    func joinCommunity(code: String, memberNumber: String, role: String = "angler") async throws -> JoinCommunityResponse {
        guard let token = await AuthService.shared.currentAccessToken() else {
            throw CommunityError.unauthenticated
        }

        let memNum = MemberNumber.normalize(memberNumber)
        guard MemberNumber.isValid(memNum) else {
            throw CommunityError.invalidMemberNumberFormat
        }

        let url = projectURL.appendingPathComponent("/functions/v1/join-community")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")

        let body: [String: String] = [
            "community_code": code.uppercased(),
            "member_number": memNum,
            "role": role
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

        let decoded = try JSONDecoder().decode(JoinCommunityResponse.self, from: data)

        switch statusCode {
        case 200:
            AppLogging.log("[CommunityService] Joined community: \(decoded.communityName ?? "?") type=\(decoded.communityType ?? "nil") id=\(decoded.communityId ?? "nil")", level: .info, category: .community)
            // Refresh memberships to pick up the new one
            await fetchMemberships()
            // Auto-select the newly joined community so the user lands directly in it
            if let newId = decoded.communityId {
                await MainActor.run {
                    setActiveCommunity(id: newId)
                }
            }
            return decoded
        case 409:
            throw CommunityError.alreadyMember(decoded.communityName ?? "Unknown")
        case 404:
            throw CommunityError.invalidCode
        case 400:
            throw CommunityError.invalidCodeFormat
        case 403:
            throw CommunityError.invalidMemberNumber
        default:
            throw CommunityError.serverError(statusCode, decoded.error ?? "Unknown error")
        }
    }

    // MARK: - Leave community

    /// Leave the given community. Server soft-deletes the user_communities row
    /// (sets left_at) and preserves dependent records (catch reports, trips,
    /// voice notes, forum posts). Caller identity comes from the JWT — never
    /// the body. Idempotent: a 404 'not_a_member' is treated as success.
    /// POST /functions/v1/leave-community
    func leaveCommunity(communityId: String) async throws {
        guard let token = await AuthService.shared.currentAccessToken() else {
            throw CommunityError.unauthenticated
        }

        let url = projectURL.appendingPathComponent("/functions/v1/leave-community")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")

        let body: [String: String] = ["community_id": communityId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

        switch statusCode {
        case 200:
            AppLogging.log("[CommunityService] Left community: id=\(communityId)", level: .info, category: .community)
        case 404:
            // Idempotent: server reports 'not_a_member' if the row was already left/missing.
            AppLogging.log("[CommunityService] Leave community 404 not_a_member — already left, treating as success", level: .info, category: .community)
        case 401:
            throw CommunityError.unauthenticated
        default:
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            AppLogging.log("[CommunityService] Leave community failed status=\(statusCode) body=\(bodyText)", level: .error, category: .community)
            throw CommunityError.serverError(statusCode, bodyText)
        }

        // Clear the active selection if it was the community we just left,
        // then refresh memberships so the picker / single-community auto-select
        // logic in fetchMemberships() can route the user to the right next state.
        await MainActor.run {
            if self.activeCommunityId == communityId {
                self.clearActiveCommunity()
            }
        }
        await fetchMemberships()
    }

    // MARK: - Fetch add-ons

    /// Fetches community_addons for the active community from the REST API.
    /// Updates the `addons` dictionary with addon_name → is_active mappings.
    func fetchAddons() async {
        guard let communityId = await MainActor.run(body: { self.activeCommunityId }),
              let token = await AuthService.shared.currentAccessToken() else {
            return
        }

        var comps = URLComponents(url: projectURL.appendingPathComponent("/rest/v1/community_addons"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "select", value: "addon_name,is_active"),
            URLQueryItem(name: "community_id", value: "eq.\(communityId)")
        ]

        var request = URLRequest(url: comps.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(statusCode) else {
                AppLogging.log("[CommunityService] Fetch addons failed status=\(statusCode)", level: .error, category: .community)
                return
            }

            struct AddonRow: Decodable {
                let addon_name: String
                let is_active: Bool
            }
            let rows = try JSONDecoder().decode([AddonRow].self, from: data)
            let dict = Dictionary(uniqueKeysWithValues: rows.map { ($0.addon_name, $0.is_active) })
            await MainActor.run {
                self.addons = dict
            }
            AppLogging.log("[CommunityService] Fetched \(rows.count) addon(s): \(dict)", level: .info, category: .community)
        } catch {
            AppLogging.log("[CommunityService] Fetch addons error: \(error)", level: .error, category: .community)
        }
    }

    // MARK: - Clear on logout

    func clear() {
        AppLogging.log("[CommunityService] Clearing community state (logout)", level: .info, category: .community)
        memberships = []
        activeCommunityId = nil
        activeRole = nil
        activeCommunityTypeId = nil
        activeCommunityTypeName = nil
        activeCommunityConfig = .default
        isMemberActive = true
        addons = [:]
        hasFetchedMemberships = false
        UserDefaults.standard.removeObject(forKey: kActiveCommunityId)
        UserDefaults.standard.removeObject(forKey: kActiveRole)
        UserDefaults.standard.removeObject(forKey: kActiveCommunityTypeId)
        UserDefaults.standard.removeObject(forKey: kActiveCommunityTypeName)
        UserDefaults.standard.removeObject(forKey: kActiveCommunityConfig)
    }

    // MARK: - Test Support

    /// Injects a community config for testing purposes.
    /// In production, config is set via fetchMemberships() → setActiveCommunity().
    func setTestConfig(_ config: CommunityConfig) {
        activeCommunityConfig = config
    }

    // MARK: - Private

    private func persistActiveState() {
        UserDefaults.standard.set(activeCommunityId, forKey: kActiveCommunityId)
        UserDefaults.standard.set(activeRole, forKey: kActiveRole)
        UserDefaults.standard.set(activeCommunityTypeId, forKey: kActiveCommunityTypeId)
        UserDefaults.standard.set(activeCommunityTypeName, forKey: kActiveCommunityTypeName)
        if let configData = try? JSONEncoder().encode(activeCommunityConfig) {
            UserDefaults.standard.set(configData, forKey: kActiveCommunityConfig)
        }
    }

    /// Shared offline branch for `fetchMemberships()`: pulls per-user cached
    /// memberships into the published list (without clobbering an existing
    /// in-memory set) and flips `hasFetchedMemberships = true` so AppRootView
    /// stops showing the launch spinner. Used by both the no-token and the
    /// offline-with-valid-token paths.
    private func hydrateFromCacheAndMarkFetched(reason: String) async {
        let cachedMemberId = AuthService.shared.currentMemberIdSnapshot
            ?? UserDefaults.standard.string(forKey: "CachedMemberId")
        let cached = Self.loadCachedMemberships(for: cachedMemberId)
        await MainActor.run {
            if !cached.isEmpty {
                if self.memberships.isEmpty {
                    self.memberships = cached
                }
                AppLogging.log("[CommunityService] Offline fetch (\(reason)): using \(cached.count) cached membership(s) for memberId=\(cachedMemberId ?? "<nil>")", level: .info, category: .community)
            } else {
                AppLogging.log("[CommunityService] Offline fetch (\(reason)): no cached memberships available for memberId=\(cachedMemberId ?? "<nil>")", level: .warn, category: .community)
            }
            self.hasFetchedMemberships = true
        }
    }

    /// Writes the memberships list under `<prefix><memberId>` so the picker
    /// can be populated on offline cold launch / offline sign-in. No-op when
    /// we don't yet know the memberId (the next successful online fetch will
    /// retry with a known ID).
    private func persistMemberships(_ list: [CommunityMembership]) {
        guard let memberId = AuthService.shared.currentMemberIdSnapshot
            ?? UserDefaults.standard.string(forKey: "CachedMemberId"),
              !memberId.isEmpty else {
            AppLogging.log("[CommunityService] persistMemberships skipped: no memberId available", level: .debug, category: .community)
            return
        }
        let key = Self.kCachedMembershipsPrefix + memberId
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
            AppLogging.log("[CommunityService] Persisted \(list.count) membership(s) (\(data.count) bytes) for memberId=\(memberId)", level: .debug, category: .community)
        } else {
            AppLogging.log("[CommunityService] persistMemberships encode failed for memberId=\(memberId)", level: .warn, category: .community)
        }
    }

    /// Pure read of the per-user cache. Returns `[]` on miss, nil memberId,
    /// or decode failure (graceful — picker just appears empty, same as
    /// pre-cache behavior).
    static func loadCachedMemberships(for memberId: String?) -> [CommunityMembership] {
        guard let memberId, !memberId.isEmpty else { return [] }
        let key = kCachedMembershipsPrefix + memberId
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        guard let decoded = try? JSONDecoder().decode([CommunityMembership].self, from: data) else {
            AppLogging.log("[CommunityService] Cached memberships decode failed for memberId=\(memberId) — backend schema may have shifted; cache will refresh on next online fetch", level: .debug, category: .community)
            return []
        }
        return decoded
    }
}

// MARK: - Errors

enum CommunityError: LocalizedError {
    case unauthenticated
    case invalidCode
    case invalidCodeFormat
    case invalidMemberNumberFormat
    case invalidMemberNumber
    case alreadyMember(String)
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .unauthenticated:
            return "Not authenticated. Please log in and try again."
        case .invalidCode:
            return "Community code not found or community is inactive."
        case .invalidCodeFormat:
            return "Invalid code format. Enter a 6-character alphanumeric code."
        case .invalidMemberNumberFormat:
            return "Invalid member number format. Enter the 9-character code from your invite email (e.g. MAD4ZQ7H9)."
        case .invalidMemberNumber:
            return "Member number does not match this community's invite. Check the code in your invite email."
        case .alreadyMember(let name):
            return "You are already a member of \(name)."
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        }
    }
}
