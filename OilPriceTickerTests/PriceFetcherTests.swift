//
//  PriceFetcherTests.swift
//  OilPriceTickerTests
//
//  Parser tests run against captured payloads so they stay meaningful even when
//  the live endpoint is rate limiting us.
//

import Foundation
import Testing
@testable import OilPriceTickerMacApp

private let host = "query1.finance.yahoo.com"

private func response(_ status: Int) -> URLResponse {
	HTTPURLResponse(
		url: URL(string: "https://\(host)/v8/finance/chart/CL=F")!,
		statusCode: status,
		httpVersion: "HTTP/1.1",
		headerFields: nil
	)!
}

/// Trimmed from a real 200 response captured on 2026-09-08.
private let liveSample = """
{"chart":{"result":[{"meta":{"currency":"USD","symbol":"CL=F","exchangeName":"NYM",\
"instrumentType":"FUTURE","regularMarketPrice":94.27,"regularMarketChangePercent":1.333,\
"fiftyTwoWeekHigh":119.48,"fiftyTwoWeekLow":54.98,"shortName":"Crude Oil Oct 26",\
"chartPreviousClose":93.03,"priceHint":2}}],"error":null}}
"""

struct PriceFetcherTests {

	@Test func parsesPriceAndContractFromLivePayload() throws {
		let quote = try PriceFetcher.parse(
			data: Data(liveSample.utf8),
			response: response(200),
			host: host
		)
		#expect(quote.price == 94.27)
		#expect(quote.contract == "Crude Oil Oct 26")
		#expect(quote.changePercent == 1.333)
		#expect(quote.source == host)
	}

	/// The exact shape Barchart started returning: success-ish status, no body.
	/// It must surface as a named error, never as a silently missing price.
	@Test func emptyBodyIsReportedNotSwallowed() {
		#expect(throws: PriceFetchError.self) {
			try PriceFetcher.parse(data: Data(), response: response(202), host: host)
		}
	}

	@Test func rateLimitIsReportedAsHTTP429() {
		var caught: PriceFetchError?
		#expect(throws: PriceFetchError.self) {
			do {
				_ = try PriceFetcher.parse(
					data: Data("Too Many Requests".utf8),
					response: response(429),
					host: host
				)
			} catch let error as PriceFetchError {
				caught = error
				throw error
			}
		}
		#expect(caught.map(PriceFetcher.isRateLimit) == true)
	}

	@Test func htmlInsteadOfJSONIsReportedAsMalformed() {
		#expect(throws: PriceFetchError.self) {
			try PriceFetcher.parse(
				data: Data("<!DOCTYPE html><html><body>nope</body></html>".utf8),
				response: response(200),
				host: host
			)
		}
	}

	@Test func feedLevelErrorIsSurfaced() {
		let payload = """
		{"chart":{"result":null,"error":{"code":"Not Found","description":"No data found for symbol"}}}
		"""
		#expect(throws: PriceFetchError.self) {
			try PriceFetcher.parse(data: Data(payload.utf8), response: response(200), host: host)
		}
	}

	@Test func missingPriceIsReportedRatherThanDefaulted() {
		let payload = """
		{"chart":{"result":[{"meta":{"shortName":"Crude Oil Oct 26"}}],"error":null}}
		"""
		#expect(throws: PriceFetchError.self) {
			try PriceFetcher.parse(data: Data(payload.utf8), response: response(200), host: host)
		}
	}
}
