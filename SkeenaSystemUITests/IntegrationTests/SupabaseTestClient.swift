import Foundation

/// Minimal Supabase REST helper used by Phase 2 integration tests to verify
/// uploaded catch reports landed in the `catch_reports` table.
///
/// Auth uses a service-role JWT supplied via launch environment so we
/// bypass RLS and can read any row by `report_id`. The key MUST come from
/// the env — never hardcode it. Setup pattern (one-shot, per shell):
///
/// ```
/// export SUPABASE_TEST_URL='https://<project-ref>.supabase.co'
/// export SUPABASE_TEST_KEY='<service-role-jwt>'
/// xcodebuild test ...
/// ```
///
/// The client is intentionally synchronous (semaphore-blocked URLSession)
/// so callers can use it from non-async XCTest methods without rewiring
/// every assertion path.
struct SupabaseTestClient {

    enum ClientError: Error, CustomStringConvertible {
        case missingURL
        case missingKey
        case badURL(String)
        case transport(Error)
        case httpStatus(Int, String)
        case decodingFailed(Error)

        var description: String {
            switch self {
            case .missingURL: return "SUPABASE_TEST_URL env var is not set"
            case .missingKey: return "SUPABASE_TEST_KEY env var is not set"
            case .badURL(let s): return "Could not construct URL from: \(s)"
            case .transport(let e): return "Transport error: \(e.localizedDescription)"
            case .httpStatus(let code, let body):
                return "Unexpected HTTP \(code). Body: \(body.prefix(500))"
            case .decodingFailed(let e):
                return "JSON decode failed: \(e.localizedDescription)"
            }
        }
    }

    let baseURL: URL
    let apiKey: String

    /// Build from env vars. Throws a clear error if either is missing so
    /// the test can `XCTSkip` with a useful message.
    static func fromEnvironment() throws -> SupabaseTestClient {
        let env = ProcessInfo.processInfo.environment
        guard let urlString = env["SUPABASE_TEST_URL"], !urlString.isEmpty else {
            throw ClientError.missingURL
        }
        guard let key = env["SUPABASE_TEST_KEY"], !key.isEmpty else {
            throw ClientError.missingKey
        }
        guard let url = URL(string: urlString) else {
            throw ClientError.badURL(urlString)
        }
        return SupabaseTestClient(baseURL: url, apiKey: key)
    }

    /// GET `/rest/v1/catch_reports?report_id=eq.<uuid>&select=*` and decode
    /// the response into `[[String: Any]]` — Supabase REST always returns
    /// an array even for single-row lookups, so callers should expect 0 or
    /// 1 elements.
    func fetchCatchReport(reportId: String) throws -> [[String: Any]] {
        let path = "/rest/v1/catch_reports"
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw ClientError.badURL("\(baseURL)\(path)")
        }
        components.queryItems = [
            URLQueryItem(name: "report_id", value: "eq.\(reportId)"),
            URLQueryItem(name: "select", value: "*"),
        ]
        guard let url = components.url else {
            throw ClientError.badURL("\(baseURL)\(path)")
        }
        return try getJSONArray(url: url)
    }

    // MARK: - Private

    private func getJSONArray(url: URL) throws -> [[String: Any]] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var data: Data?
        var response: URLResponse?
        var transportError: Error?

        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { d, r, e in
            data = d; response = r; transportError = e
            semaphore.signal()
        }.resume()
        // Generous timeout — Supabase REST is normally <500ms but cold
        // edge functions can spike. Tests overall are gated by
        // executionTimeAllowance so blocking here is fine.
        _ = semaphore.wait(timeout: .now() + 30)

        if let error = transportError { throw ClientError.transport(error) }

        let bodyText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.httpStatus(http.statusCode, bodyText)
        }

        guard let payload = data else { return [] }
        do {
            let any = try JSONSerialization.jsonObject(with: payload, options: [])
            return (any as? [[String: Any]]) ?? []
        } catch {
            throw ClientError.decodingFailed(error)
        }
    }
}
