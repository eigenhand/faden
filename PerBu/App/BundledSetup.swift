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

    /// Verified against `/v1/model/info`: 1 048 576 in, 64 000 out, vision, reasoning,
    /// tool calling and prompt caching all supported.
    ///
    /// Chosen over `qwen/qwen3.8-flash-next` for latency. Measured on the same
    /// one-word question, glm answered in 12 s and qwen in 72 s — six times longer,
    /// and multiplied again by every tool round. At that point it does not read as
    /// slow, it reads as broken.
    static let chatModel = "z-ai/glm-5.3-flash"
    static let contextWindow = 1_048_576
    static let maxOutputTokens = 64_000

    static let embeddingPath = "/v1/embeddings"
    static let embeddingModel = "qwen/qwen3-embedding-8b"

    static let keychainAccount = "perbu.bundled.key"
    static let searchKeychainAccount = "perbu.bundled.search"
}
