import Foundation

/// A provider baked into the build, so a tester can open the app and start typing.
///
/// PerBu's premise is that it brings no infrastructure — you supply the endpoint, the
/// key and the model. That premise is unchanged for anyone who installs it normally:
/// with no key compiled in, `isManaged` is false and every setup screen behaves as
/// before.
///
/// A TestFlight build for a closed circle of friends is the one case where that
/// premise gets in the way. They have no endpoint of their own, and asking them to
/// find one before they can judge the app means testing the setup form rather than
/// the app. So the release script writes a key in here, and a build carrying one
/// configures itself on first launch and hides the model plumbing, because in that
/// build there is nothing to choose.
///
/// The key in a shipped binary is readable by whoever holds the binary — a string in
/// the app, a proxy certificate on the device, a debugger on the process. This is a
/// deliberate trade for a build that goes to named testers, not a mistake. Use a key
/// issued for that purpose alone so it can be revoked without touching anything else;
/// TensorX reports cost and token counts per key, so the beta's consumption stays
/// separate and visible.
enum BundledSetup {

    // Filled in by `release.sh` from `.release.env`, and blanked again afterwards so
    // the working tree never keeps it. Empty here on purpose.
    static let apiKey = ""
    static let searchKey = ""

    /// True when this build carries its own provider.
    static var isManaged: Bool { !apiKey.isEmpty }
    /// True when this build also carries a web-search key.
    static var hasSearch: Bool { !searchKey.isEmpty }

    // MARK: What gets configured

    static let baseURL = "https://api.tensorx.ai"
    static let chatPath = "/v1/chat/completions"
    static let providerName = "TensorX"

    /// Verified against `/v1/model/info`: 1 048 576 in, 64 000 out, reasoning, tool
    /// calling and prompt caching supported — **Bilder nicht**.
    ///
    /// Das ist der Preis dieser Wahl und er ist gemessen, nicht vermutet. Dasselbe
    /// Bild an beide Modelle geschickt: `-flash` antwortet „Orange, Violett",
    /// `glm-5.3` weist es mit HTTP 400 ab, „Model only supports text input". Die
    /// Geschwindigkeit ist dabei kein Argument mehr in eine der beiden Richtungen —
    /// auf dieselbe Ein-Wort-Frage 2,4 s gegen 2,5 s.
    ///
    /// Wer Bilder anhängen will, stellt in den Einstellungen ein Modell ein, das sie
    /// sieht; `z-ai/glm-5.3-flash` steht beim selben Anbieter.
    static let chatModel = "z-ai/glm-5.3"

    /// Woraufhin ausgewichen wird, wenn das Hauptmodell nicht antwortet.
    ///
    /// Es ist das langsamere der beiden — gemessen 72 s gegen 12 s auf derselben
    /// Frage, weshalb es nicht das Hauptmodell ist. Als Ausweichmodell ist genau das
    /// die richtige Wahl: langsam schlägt kaputt. Ein Anbieter nimmt selten zwei
    /// Modelle gleichzeitig vom Netz.
    static let fallbackChatModel = "qwen/qwen3.8-flash-next"

    /// Ob das mitgelieferte Modell Bilder annimmt.
    ///
    /// Steht hier und nicht als `true` im `AppModel`, weil es eine Eigenschaft des
    /// Modells ist und mit ihm zusammen wandern muss. Genau daran hing der Fehler
    /// schon einmal andersherum: ein Gerät behielt die Einschätzung eines älteren
    /// Baus, das Pluszeichen blieb weg, und in der App war es nicht mehr zu
    /// korrigieren. Eine Behauptung, die neben dem Modellnamen steht, kann nicht
    /// mit ihm auseinanderlaufen.
    static let chatModelSeesImages = false
    static let contextWindow = 1_048_576
    static let maxOutputTokens = 64_000

    static let embeddingPath = "/v1/embeddings"
    static let embeddingModel = "qwen/qwen3-embedding-8b"

    static let keychainAccount = "perbu.bundled.key"
    static let searchKeychainAccount = "perbu.bundled.search"
}
