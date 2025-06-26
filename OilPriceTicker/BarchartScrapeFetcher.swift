//OilPriceTicker/BarchartScrapeFetcher.swift
import Foundation
import Combine
import OSLog
import SwiftSoup

struct BarchartScrapeFetcher {
	private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OilPriceTicker", category: "BarchartScrape")
	private let url = URL(string: "https://www.barchart.com/futures/quotes/CL*0")!
	func fetchPrice() -> AnyPublisher<Double?, Never> {
		URLSession.shared.dataTaskPublisher(for: url)
			.tryMap { data, _ in
				guard let html = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeRawData) }
				if let price = Self.extractViaRegex(html) { return price }
				let doc = try SwiftSoup.parse(html)
				if let span = try doc.select("span.last-price").first(),
					let text = try? span.text(),
					let price = Double(text.replacingOccurrences(of: ",", with: "")) {
					return price
				}
				throw URLError(.cannotParseResponse)
			}
			.map(Optional.some)
			.replaceError(with: nil)
			.handleEvents(receiveOutput: { price in
				if let p = price {
					Self.logger.debug("Scraped price: \(p)")
				} else { Self.logger.error("Barchart scrape failed") }
			})
			.eraseToAnyPublisher()
	}
	private static func extractViaRegex(_ html: String) -> Double? {
		let pattern = "\\\"lastPrice\\\"\\s*:\\s*([0-9]+\\.?[0-9]*)"
		guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
		if let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: html.utf16.count)),
			let range = Range(match.range(at: 1), in: html) {
			return Double(String(html[range]))
		}
		return nil
	}
} 