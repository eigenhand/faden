import XCTest
@testable import Faden

/// Wohin `fetch_page` greifen darf.
///
/// Der Unterschied zum Suchanbieter ist der Anlass: dessen Adresse hat der Nutzer
/// eingetragen und sie darf ins eigene Netz zeigen — bei einem selbst betriebenen
/// SearXNG tut sie das. Die Adresse fuer `fetch_page` waehlt dagegen das Modell, nach
/// dem, was in einem Suchergebnis oder auf einer Seite stand. Das ist eine Eingabe
/// von aussen.
///
/// Was sonst moeglich waere: eine praeparierte Seite nennt die Adresse des Routers,
/// das Modell laedt sie und schreibt den Inhalt in die Antwort. Das Telefon steht im
/// selben WLAN — es kommt dorthin, wo der Angreifer nicht hinkommt.
final class FetchTargetTests: XCTestCase {

    private func allowed(_ s: String) -> Bool {
        guard let url = URL(string: s) else { return false }
        return FetchTarget.isAllowed(url)
    }

    // MARK: Was durchkommt

    func testOrdinaryPublicAddressesPass() {
        XCTAssertTrue(allowed("https://de.wikipedia.org/wiki/Kabel"))
        XCTAssertTrue(allowed("http://wttr.in/Berlin"))
        XCTAssertTrue(allowed("https://example.org:8443/pfad?a=b"))
        XCTAssertTrue(allowed("https://8.8.8.8/"), "Eine oeffentliche IP ist erlaubt.")
        XCTAssertTrue(allowed("https://172.32.0.1/"), "172.32 liegt schon ausserhalb von 172.16/12.")
        XCTAssertTrue(allowed("https://11.0.0.1/"), "Nur 10/8 ist privat, nicht 11/8.")
    }

    /// Ein Name mit Ziffern ist kein Zahlengebilde: `192.168.example.com` ist eine
    /// ganz gewoehnliche Domain und darf nicht an der IP-Pruefung haengenbleiben.
    func testANameThatLooksNumericIsStillAName() {
        XCTAssertTrue(allowed("https://192.168.example.com/"))
        XCTAssertTrue(allowed("https://10.0.0.1.example.org/"))
    }

    // MARK: Was nicht durchkommt

    func testTheDeviceItself() {
        XCTAssertFalse(allowed("http://localhost:11434/api"))
        XCTAssertFalse(allowed("http://127.0.0.1/"))
        XCTAssertFalse(allowed("http://127.1.2.3/"), "Das ganze 127/8 zeigt auf das Geraet.")
        XCTAssertFalse(allowed("http://[::1]/"))
    }

    func testTheHomeNetwork() {
        XCTAssertFalse(allowed("http://192.168.178.1/status"), "Der Router.")
        XCTAssertFalse(allowed("https://10.1.2.3/"))
        XCTAssertFalse(allowed("https://172.16.0.1/"))
        XCTAssertFalse(allowed("https://172.31.255.254/"))
        XCTAssertFalse(allowed("http://drucker.local/"))
        XCTAssertFalse(allowed("http://nas.lan/"))
    }

    /// 169.254.169.254 ist die Adresse, unter der Cloud-Anbieter ihre Zugangsdaten
    /// herausgeben. Sie steht hier, weil sie das bekannteste Ziel dieser Angriffsart
    /// ueberhaupt ist — auf einem Telefon harmlos, in einer Serverumgebung nicht.
    func testTheLinkLocalRangeIncludingTheMetadataAddress() {
        XCTAssertFalse(allowed("http://169.254.169.254/latest/meta-data/"))
        XCTAssertFalse(allowed("http://169.254.0.1/"))
    }

    func testOtherSchemesAndBrokenAddresses() {
        XCTAssertFalse(allowed("file:///etc/passwd"))
        XCTAssertFalse(allowed("ftp://example.org/"))
        XCTAssertFalse(allowed("data:text/html,<h1>hi"))
        XCTAssertFalse(allowed("https://"), "Ohne Host gibt es nichts zu laden.")
    }

    func testUniqueLocalAndLinkLocalIPv6() {
        XCTAssertFalse(allowed("http://[fd00::1]/"))
        XCTAssertFalse(allowed("http://[fe80::1]/"))
        XCTAssertTrue(allowed("http://[2606:4700:4700::1111]/"), "Oeffentliches IPv6 darf.")
    }

    /// Eine in IPv6 eingebettete private IPv4-Adresse ist derselbe Weg mit anderer
    /// Schreibweise.
    func testAnIPv4AddressHiddenInsideIPv6() {
        XCTAssertFalse(allowed("http://[::ffff:192.168.0.1]/"))
    }

    // MARK: Die Begruendung

    /// Das Modell bekommt den Satz als Werkzeugantwort. Ohne ihn versucht es dieselbe
    /// Adresse noch dreimal, weil es wie ein Fehler der Seite aussaehe.
    func testTheRefusalSaysWhy() throws {
        let url = try XCTUnwrap(URL(string: "http://192.168.178.1/"))
        let reason = try XCTUnwrap(FetchTarget.refusal(for: url))
        XCTAssertTrue(reason.contains("lokale"), reason)
        XCTAssertNil(FetchTarget.refusal(for: try XCTUnwrap(URL(string: "https://example.org"))))
    }
}
