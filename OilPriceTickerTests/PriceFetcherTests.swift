//
//  PriceFetcherTests.swift
//  OilPriceTickerTests
//
//  Parser tests run against captured relay payloads, so they never depend on
//  the live relay or on any quote site.
//

import Foundation
import Testing
@testable import OilPriceTickerMacApp

private let host = "wti.oil-price.workers.dev"

private func response(_ status: Int) -> URLResponse {
	HTTPURLResponse(
		url: URL(string: "https://\(host)/")!,
		statusCode: status,
		httpVersion: "HTTP/1.1",
		headerFields: nil
	)!
}

private func parse(_ payload: String, status: Int = 200) throws -> OilQuote {
	try PriceFetcher.parse(data: Data(payload.utf8), response: response(status), host: host)
}

/// Captured from the deployed relay on 2026-10-01.
private let liveSample = """
{"quote":{"price":93.01,"changePercent":0.151,"contract":"Crude Oil Nov 26","quoteTime":"2026-10-01T23:10:25.000Z","source":"yahoo"},\
"fetchedAt":"2026-10-01T23:20:30.265Z",\
"lastAttempt":{"at":"2026-10-01T23:20:30.265Z","ok":true,"failures":[{"source":"cnbc","reason":"HTTP 403"}]}}
"""

private func iso(_ s: String) -> Date {
	let f = ISO8601DateFormatter()
	f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
	return f.date(from: s)!
}

struct PriceFetcherTests {

	@Test func parsesQuoteFromLiveRelayPayload() throws {
		let quote = try parse(liveSample)
		#expect(quote.price == 93.01)
		#expect(quote.contract == "Crude Oil Nov 26")
		#expect(quote.changePercent == 0.151)
		#expect(quote.source == "yahoo")
		#expect(quote.quoteTime == iso("2026-10-01T23:10:25.000Z"))
		#expect(quote.fetchedAt == iso("2026-10-01T23:20:30.265Z"))
	}

	/// A source the relay skipped past is not a problem for the price, but the
	/// tooltip should still be able to say what the relay hit.
	@Test func relayAttemptOkMeansNoRelayFailure() throws {
		#expect(try parse(liveSample).relayFailure == nil)
	}

	/// Every upstream failed on the relay's last run: the price is the old one,
	/// and the reasons must reach the app rather than vanish.
	@Test func failedRelayAttemptIsCarriedWithItsReasons() throws {
		let payload = """
		{"quote":{"price":93.01,"changePercent":null,"contract":null,"quoteTime":null,"source":"tradingview"},\
		"fetchedAt":"2026-10-01T23:20:30.265Z",\
		"lastAttempt":{"at":"2026-10-01T23:45:30.000Z","ok":false,"failures":[\
		{"source":"cnbc","reason":"HTTP 403"},{"source":"yahoo","reason":"HTTP 429"}]}}
		"""
		let quote = try parse(payload)
		#expect(quote.quoteTime == nil)
		#expect(quote.relayFailure?.contains("cnbc: HTTP 403") == true)
		#expect(quote.relayFailure?.contains("yahoo: HTTP 429") == true)
	}

	/// Before its first successful run the relay answers 503 with no quote. That
	/// must surface the relay's own explanation, not a bare status code.
	@Test func relayWithNoQuoteYetIsReportedWithItsReason() {
		let payload = """
		{"quote":null,"fetchedAt":null,"lastAttempt":{"at":"2026-10-01T23:45:30.000Z","ok":false,\
		"failures":[{"source":"cnbc","reason":"HTTP 403"}]},"error":"no quote fetched yet"}
		"""
		var caught: PriceFetchError?
		#expect(throws: PriceFetchError.self) {
			do { _ = try parse(payload, status: 503) } catch let e as PriceFetchError { caught = e; throw e }
		}
		#expect(caught?.localizedDescription.contains("cnbc: HTTP 403") == true)
	}

	@Test func emptyBodyIsReportedNotSwallowed() {
		#expect(throws: PriceFetchError.self) {
			try PriceFetcher.parse(data: Data(), response: response(202), host: host)
		}
	}

	@Test func htmlInsteadOfJSONIsReportedAsMalformed() {
		#expect(throws: PriceFetchError.self) {
			try parse("<!DOCTYPE html><html><body>nope</body></html>")
		}
	}

	@Test func zeroPriceIsReportedRatherThanShown() {
		let payload = liveSample.replacingOccurrences(of: "\"price\":93.01", with: "\"price\":0")
		#expect(throws: PriceFetchError.self) { try parse(payload) }
	}

	@Test func unexpectedHTTPStatusIsReported() {
		#expect(throws: PriceFetchError.self) { try parse("oops", status: 500) }
	}
}
