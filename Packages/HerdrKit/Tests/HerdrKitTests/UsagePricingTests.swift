import XCTest
@testable import HerdrKit

/// The usage pricing table: longest-prefix model matching, the
/// approximate cheapest-rate fallback for unknown models, and the exact
/// cost math over `UsageTokens`.
final class UsagePricingTests: XCTestCase {
    /// A dated Claude model string bills at its `claude-opus-5-5` row; a
    /// gpt-6 family string bills at its exact family row.
    func testPrefixMatchUsesLongestPrefix() {
        let tokens = UsageTokens(
            input: 1_000_000, output: 1_000_000, reasoning: 0,
            cacheRead: 0, cacheWrite: 0)
        let dated = UsagePricing.cost(of: tokens, model: "claude-opus-5-5-20261001")
        XCTAssertEqual(dated.dollars, 24.0, accuracy: 1e-12) // $4 in + $20 out
        XCTAssertEqual(dated.approximate, false)
        XCTAssertEqual(
            dated.dollars,
            UsagePricing.cost(of: tokens, model: "claude-opus-5-5").dollars,
            accuracy: 1e-12)
        let astra = UsagePricing.cost(of: tokens, model: "gpt-6-astra-2026-09-30")
        XCTAssertEqual(astra.dollars, 60.0, accuracy: 1e-12) // $10 in + $50 out
        XCTAssertEqual(astra.approximate, false)
    }

    /// Every seeded row keeps cache reads at a fraction of its own input
    /// rate and cache writes under 1.25x of it. 0.25x is the loosest real
    /// read multiplier — z.ai bills cached input at $0.26 against a $1.4
    /// input (~0.186x); reads still sit far below the input rate.
    func testCacheMultipliersMatchTable() {
        XCTAssertFalse(UsagePricing.table.isEmpty)
        for rate in UsagePricing.table {
            XCTAssertLessThanOrEqual(
                rate.cacheRead, rate.input * 0.25, "\(rate.prefix): cache read")
            XCTAssertLessThanOrEqual(
                rate.cacheWrite, rate.input * 1.25, "\(rate.prefix): cache write")
        }
    }

    /// A model no row matches bills every token class at the table's
    /// cheapest rate and flags itself approximate; a known model is exact.
    func testUnknownModelFallsBackToCheapest() throws {
        let tokens = UsageTokens(
            input: 1_000_000, output: 1_000_000, reasoning: 0,
            cacheRead: 1_000_000, cacheWrite: 1_000_000)
        let input = try XCTUnwrap(UsagePricing.table.map(\.input).min())
        let output = try XCTUnwrap(UsagePricing.table.map(\.output).min())
        let cacheRead = try XCTUnwrap(UsagePricing.table.map(\.cacheRead).min())
        let cacheWrite = try XCTUnwrap(UsagePricing.table.map(\.cacheWrite).min())
        let fallback = UsagePricing.cost(of: tokens, model: "some-future-model-9")
        XCTAssertTrue(fallback.approximate)
        XCTAssertEqual(
            fallback.dollars, input + output + cacheRead + cacheWrite, accuracy: 1e-12)
        XCTAssertFalse(UsagePricing.cost(of: tokens, model: "glm-5.3").approximate)
    }

    /// The pinned math on round numbers: each token class times its rate,
    /// reasoning as output. gpt-6.1-sol: $2 in / $10 out / $0.10 read /
    /// $2.50 write per 1M.
    func testCostMathIsExact() {
        let tokens = UsageTokens(
            input: 2_000_000, output: 1_000_000, reasoning: 500_000,
            cacheRead: 4_000_000, cacheWrite: 200_000)
        // 2×$2.00 + 1×$10.00 + 0.5×$10.00 + 4×$0.10 + 0.2×$2.50
        let cost = UsagePricing.cost(of: tokens, model: "gpt-6.1-sol")
        XCTAssertEqual(cost.dollars, 19.9, accuracy: 1e-10)
        XCTAssertEqual(cost.approximate, false)
    }
}
