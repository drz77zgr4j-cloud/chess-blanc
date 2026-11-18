import Foundation

/// The one way the app talks to chess.com and Lichess: no cookies or cache kept on disk, an honest
/// User-Agent (both services ask for one that names the app and a way to find it), and checked inputs.
enum Net {
    static let userAgent = "ChessBlanc/1.0 (+https://drz77zgr4j-cloud.github.io/chess-blanc/)"

    /// Nothing stored between launches: the app only reads public data.
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 120
        c.httpCookieStorage = nil
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    /// Largest response the app will parse (a month of games from a very active account is a few MB).
    static let maxBytes = 25 * 1024 * 1024

    /// chess.com and Lichess usernames are letters, digits, "_" and "-", up to 30 characters.
    static func username(_ raw: String) -> String? {
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (1...30).contains(n.count), n.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
            return nil
        }
        return n
    }

    /// Only fetch follow-up addresses (archive months, profile pictures) from the services' own hosts.
    static func trusted(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "api.chess.com" || host.hasSuffix(".chess.com") || host == "chess.com"
            || host.hasSuffix("chesscomfiles.com") || host == "lichess.org" || host.hasSuffix(".lichess.org")
    }
}
