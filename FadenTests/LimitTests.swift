import XCTest
@testable import Faden

/// Limits a provider names in a refusal.
///
/// Until just now the app asked for them: a request with `max_tokens: 99999999`, and the
/// real limit could be read out of the refusal. That worked — and is gone, because the
/// app should not invent numbers to sound out limits.
///
/// That makes this reading more important rather than less: it is now the only route by
/// which a provider without published limits tells the app its own. The samples below
/// are real error texts in the wordings that are in circulation — the place where a
/// regular expression that is too strict quietly finds nothing and nobody notices.
final class LimitTests: XCTestCase {

    func testOpenAIStyleContextMessage() {
        let body = """
        {"error": {"message": "This model's maximum context length is 128000 tokens. \
        However, you requested 130000 tokens.", "type": "invalid_request_error"}}
        """
        let limits = ModelCatalog.extractLimits(from: body)
        XCTAssertEqual(limits.context, 128_000)
    }

    func testAnOutputCeilingNamedAfterMaxTokens() {
        let body = """
        {"error": {"message": "max_tokens must be less than or equal to 8192"}}
        """
        let limits = ModelCatalog.extractLimits(from: body)
        XCTAssertEqual(limits.output, 8192)
    }

    func testTheWordyVariant() {
        let body = "maximum number of output tokens for this model is 16384"
        XCTAssertEqual(ModelCatalog.extractLimits(from: body).output, 16_384)
    }

    func testContextWindowSpelledAsAWindow() {
        let body = "Request exceeds the maximum context window of 32768 tokens."
        XCTAssertEqual(ModelCatalog.extractLimits(from: body).context, 32_768)
    }

    /// An error without a number must set nothing. Were that otherwise, the first
    /// network outage would write an invented limit into the settings.
    func testAMessageWithoutNumbersChangesNothing() {
        let limits = ModelCatalog.extractLimits(from: "Internal server error")
        XCTAssertNil(limits.context)
        XCTAssertNil(limits.output)
    }

    /// Numbers outside any plausible size are not limits but timestamps, error numbers
    /// or identifiers that happen to stand beside them.
    func testImplausibleNumbersAreIgnored() {
        XCTAssertNil(ModelCatalog.extractLimits(from: "max_tokens 12").output,
                     "Twelve tokens is not a limit, that is a typo.")
        XCTAssertNil(ModelCatalog.extractLimits(from: "max_tokens 99999999999").output,
                     "Nor is a hundred billion.")
    }

    /// The refusal names both — then both are learned.
    func testBothCeilingsAtOnce() {
        let body = """
        {"error": {"message": "max_tokens must be <= 4096; this model's maximum \
        context length is 200000 tokens"}}
        """
        let limits = ModelCatalog.extractLimits(from: body)
        XCTAssertEqual(limits.output, 4096)
        XCTAssertEqual(limits.context, 200_000)
    }
}
