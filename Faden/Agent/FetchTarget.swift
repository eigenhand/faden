import Foundation

/// Wohin `fetch_page` greifen darf — und wohin nicht.
///
/// Der Unterschied zum Suchanbieter ist der ganze Grund, warum es diese Datei gibt.
/// Die Adresse des Suchanbieters hat der Nutzer eingetragen; sie darf ins eigene
/// Netz zeigen, und bei einem selbst betriebenen SearXNG tut sie das auch. Die
/// Adresse, die `fetch_page` bekommt, wählt dagegen **das Modell** — nach dem, was in
/// einem Suchergebnis oder auf einer Seite stand. Damit ist sie eine Eingabe von
/// aussen, und eine Eingabe von aussen darf nicht ins Heimnetz zeigen.
///
/// Was sonst möglich wäre: eine präparierte Seite nennt `https://192.168.178.1/status`
/// oder die Adresse des Druckers, das Modell lädt sie und schreibt den Inhalt in die
/// Antwort. Das Telefon steht im selben WLAN wie der Router — es kommt dort hin, wo
/// der Angreifer nicht hinkommt. Genau das ist der Witz an dieser Angriffsart.
///
/// **Was das hier nicht löst**, und das gehört dazu: Ein Name, der öffentlich
/// aussieht und auf eine private Adresse zeigt, kommt durch. Dagegen hilft nur ein
/// eigener Namensauflöser, der die Adresse prüft und dann *diese* verwendet — sonst
/// bleibt zwischen Prüfung und Verbindung ein Spalt, in dem sich die Antwort ändern
/// kann. Das wäre eine eigene Netzwerkschicht. Was hier steht, deckt den Fall ab, der
/// ohne Aufwand funktioniert: die Adresse direkt hinschreiben.
enum FetchTarget {

    /// Der Grund, warum diese Adresse nicht geladen wird — oder nil, wenn sie darf.
    ///
    /// Gibt einen Satz zurück und nicht nur ja/nein: Das Modell bekommt ihn als
    /// Werkzeugantwort und soll wissen, dass es an der Adresse lag und nicht an der
    /// Seite. Sonst versucht es dieselbe noch dreimal.
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

    /// Namen, die per Definition auf das eigene Gerät oder das eigene Netz zeigen.
    static func isLocalName(_ host: String) -> Bool {
        if host == "localhost" { return true }
        for suffix in [".localhost", ".local", ".internal", ".home", ".lan"]
        where host.hasSuffix(suffix) { return true }
        return false
    }

    /// Adressen, die nicht im öffentlichen Netz liegen.
    ///
    /// Geprüft wird die geschriebene Adresse, nicht das Ergebnis einer Namensauflösung
    /// — siehe oben, warum das die halbe Miete ist und warum die andere Hälfte eine
    /// eigene Netzwerkschicht wäre.
    static func isPrivateAddress(_ host: String) -> Bool {
        // IPv6 steht in URLs in eckigen Klammern; `URL.host` gibt sie ohne zurück.
        if host.contains(":") { return isPrivateIPv6(host) }
        guard let v4 = ipv4(host) else { return false }
        return isPrivateIPv4(v4)
    }

    /// Vier Zahlen, sonst nichts. „1.2.3" oder „foo.bar" sind keine Adresse, sondern
    /// ein Name — und Namen entscheidet diese Funktion nicht.
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
        // Ein Zonenindex („%en0") gehört zum lokalen Netz, sonst stünde er nicht da.
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

/// Prüft jede Weiterleitung noch einmal.
///
/// Ohne das wäre die Prüfung oben ein Türsteher, der nur den ersten Gast anschaut:
/// eine öffentliche Adresse antwortet mit „301 nach 192.168.178.1", und `URLSession`
/// folgt von sich aus. Der Rückgabewert nil bricht die Weiterleitung ab; die Antwort
/// bleibt dann der 3xx-Status, und der Aufrufer sagt dem Modell, was passiert ist.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, FetchTarget.isAllowed(url) else { return nil }
        return request
    }
}
