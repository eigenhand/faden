import Foundation

/// Where `fetch_page` may reach — and where not.
///
/// The difference from the search provider is the whole reason this file exists. The
/// search provider's address was entered by the user; it may point into their own
/// network, and with a self-hosted SearXNG it does. The address `fetch_page` receives,
/// by contrast, is chosen by **the model** — according to what stood in a search result
/// or on a page. That makes it input from outside, and input from outside must not point
/// into the home network.
///
/// What would otherwise be possible: a prepared page names `https://192.168.178.1/status`
/// or the printer's address, the model loads it and writes the contents into the answer.
/// The phone sits on the same Wi-Fi as the router — it reaches where the attacker cannot.
/// That is precisely the point of this kind of attack.
///
/// **What this does not solve**, and that belongs here: a name that looks public and
/// points at a private address gets through. Only a resolver of our own would help — one
/// that checks the address and then uses *that* one — because otherwise a gap remains
/// between the check and the connection in which the answer can change. That would be a
/// network layer of its own. What stands here covers the case that works without effort:
/// writing the address down directly.
enum FetchTarget {

    /// The reason this address is not loaded — or nil when it may be.
    ///
    /// Returns a sentence and not just yes/no: the model receives it as a tool result
    /// and should know that it was down to the address and not to the page. Otherwise it
    /// tries the same one three more times.
    static func refusal(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return "Nur http und https."
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return "Der Adresse fehlt der Host."
        }
        if isLocalName(host) || isPrivateAddress(host) {
            return "Diese Adresse liegt im lokalen Netz. Werkzeuge laden nur öffentliche Seiten."
        }
        return nil
    }

    static func isAllowed(_ url: URL) -> Bool { refusal(for: url) == nil }

    /// Names that by definition point at this device or this network.
    static func isLocalName(_ host: String) -> Bool {
        if host == "localhost" { return true }
        for suffix in [".localhost", ".local", ".internal", ".home", ".lan"]
        where host.hasSuffix(suffix) { return true }
        return false
    }

    /// Addresses that do not lie on the public network.
    ///
    /// What is checked is the written address, not the result of a name resolution — see
    /// above for why that is half the job and why the other half would be a network
    /// layer of its own.
    static func isPrivateAddress(_ host: String) -> Bool {
        // IPv6 stands in URLs in square brackets; `URL.host` returns it without them.
        if host.contains(":") { return isPrivateIPv6(host) }
        guard let v4 = ipv4(host) else { return false }
        return isPrivateIPv4(v4)
    }

    /// Four numbers and nothing else. “1.2.3” or “foo.bar” are not an address but a
    /// name — and names are not this function's decision.
    static func ipv4(_ host: String) -> (UInt8, UInt8, UInt8, UInt8)? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let n = UInt16(part), n <= 255
            else { return nil }
            octets.append(UInt8(n))
        }
        return (octets[0], octets[1], octets[2], octets[3])
    }

    static func isPrivateIPv4(_ a: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        switch a {
        case (0, _, _, _):            return true   // „dieses Netz"
        case (10, _, _, _):           return true   // privat
        case (127, _, _, _):          return true   // das Gerät selbst
        case (169, 254, _, _):        return true   // link-local, auch die Metadaten-Adresse
        case (172, 16...31, _, _):    return true   // privat
        case (192, 168, _, _):        return true   // privat
        case (100, 64...127, _, _):   return true   // Carrier-NAT
        case (198, 18...19, _, _):    return true   // Messzwecke
        case (224...239, _, _, _):    return true   // Multicast
        case (240...255, _, _, _):    return true   // reserviert, inkl. Broadcast
        default:                      return false
        }
    }

    static func isPrivateIPv6(_ host: String) -> Bool {
        let h = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
        // A zone index (“%en0”) belongs to the local network, or it would not be there.
        if h.contains("%") { return true }
        let bare = h.lowercased()
        if bare == "::1" || bare == "::" { return true }
        if bare.hasPrefix("fe8") || bare.hasPrefix("fe9")
            || bare.hasPrefix("fea") || bare.hasPrefix("feb") { return true }   // link-local
        if bare.hasPrefix("fc") || bare.hasPrefix("fd") { return true }         // unique local
        // In IPv6 eingebettete IPv4-Adresse: ::ffff:192.168.0.1
        if let last = bare.split(separator: ":").last, last.contains("."),
           let v4 = ipv4(String(last)) {
            return isPrivateIPv4(v4)
        }
        return false
    }
}

/// Checks every redirect again.
///
/// Without this the check above would be a doorman who only looks at the first guest: a
/// public address answers with “301 to 192.168.178.1”, and `URLSession` follows of its
/// own accord. Returning nil aborts the redirect; the response then stays the 3xx
/// status, and the caller tells the model what happened.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, FetchTarget.isAllowed(url) else { return nil }
        return request
    }
}
