import Foundation

enum OllamaEndpointValidator {
    enum ValidationError: LocalizedError, Equatable {
        case empty
        case invalidURL
        case disallowedScheme(String)
        case disallowedHost(String)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Ollama base URL is empty."
            case .invalidURL:
                return "Ollama base URL is invalid."
            case .disallowedScheme(let scheme):
                return "Ollama URL scheme '\(scheme)' is not allowed (use http or https)."
            case .disallowedHost(let host):
                return "Ollama host '\(host)' is not allowed. Use localhost / 127.0.0.1 / ::1, or a private LAN address."
            }
        }
    }

    /// Normalizes and validates the Ollama base URL to reduce SSRF / unexpected scheme risk.
    static func validatedBaseURL(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty }

        guard var components = URLComponents(string: trimmed) else {
            throw ValidationError.invalidURL
        }
        let scheme = (components.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw ValidationError.disallowedScheme(scheme.isEmpty ? "(missing)" : scheme)
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            throw ValidationError.invalidURL
        }
        guard isAllowedHost(host) else {
            throw ValidationError.disallowedHost(host)
        }

        // Drop path/query/userinfo — only origin is used.
        components.user = nil
        components.password = nil
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw ValidationError.invalidURL }
        return url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func isAllowedHost(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" {
            return true
        }
        // IPv4 private / link-local
        if let ipv4 = parseIPv4(host) {
            let (a, b, _, _) = ipv4
            if a == 10 { return true }
            if a == 127 { return true }
            if a == 192 && b == 168 { return true }
            if a == 172 && (16...31).contains(b) { return true }
            if a == 169 && b == 254 { return true }
            return false
        }
        // .local mDNS (home Lab hosts)
        if host.hasSuffix(".local") { return true }
        return false
    }

    private static func parseIPv4(_ host: String) -> (Int, Int, Int, Int)? {
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count == 4,
              let a = Int(parts[0]), let b = Int(parts[1]),
              let c = Int(parts[2]), let d = Int(parts[3]),
              (0...255).contains(a), (0...255).contains(b),
              (0...255).contains(c), (0...255).contains(d)
        else { return nil }
        return (a, b, c, d)
    }
}
