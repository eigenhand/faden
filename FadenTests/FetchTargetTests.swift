import XCTest
@testable import Faden

/// Where `fetch_page` may reach.
///
/// The difference from the search provider is the occasion: its address was entered by
/// the user and may point into their own network — with a self-hosted SearXNG it does.
/// The address for `fetch_page`, by contrast, is chosen by the model, according to what
/// stood in a search result or on a page. That is input from outside.
///
/// What would otherwise be possible: a prepared page names the router's address, the
/// model loads it and writes the contents into the answer. The phone sits on the same
/// Wi-Fi — it reaches where the attacker cannot.
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

    /// A name with digits is not a numeric construct: `192.168.example.com` is a
    /// perfectly ordinary domain and must not get caught on the IP check.
    func testANameThatLooksNumericIsStillAName() {
        XCTAssertTrue(allowed("https://192.168.example.com/"))
        XCTAssertTrue(allowed("https://10.0.0.1.example.org/"))
    }

    // MARK: What does not get through

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

    /// 169.254.169.254 is the address at which cloud providers hand out their
    /// credentials. It stands here because it is the best-known target of this kind of
    /// attack — harmless on a phone, not in a server environment.
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

    /// A private IPv4 address embedded in IPv6 is the same route in a different
    /// spelling.
    func testAnIPv4AddressHiddenInsideIPv6() {
        XCTAssertFalse(allowed("http://[::ffff:192.168.0.1]/"))
    }

    // MARK: Die Begruendung

    /// The model receives the sentence as a tool result. Without it, it tries the same
    /// address three more times, because it would look like a fault of the page.
    func testTheRefusalSaysWhy() throws {
        let url = try XCTUnwrap(URL(string: "http://192.168.178.1/"))
        let reason = try XCTUnwrap(FetchTarget.refusal(for: url))
        XCTAssertTrue(reason.contains("lokale"), reason)
        XCTAssertNil(FetchTarget.refusal(for: try XCTUnwrap(URL(string: "https://example.org"))))
    }
}
