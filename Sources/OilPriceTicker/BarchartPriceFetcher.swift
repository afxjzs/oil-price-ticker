import Foundation
import Combine
import os.log
import OSLog

/// Fetches delayed WTI futures price from Barchart's public core-api endpoint.
struct BarchartPriceFetcher {
	private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OilPriceTicker", category: "Network")
	
	/// Publisher emitting the latest price (or `nil` on failure).
	func fetchPrice(symbol: String = "CLN25", fields: String = "lastPrice") -> AnyPublisher<Double?, Never> {
		guard let url = makeURL(symbol: symbol, fields: fields) else {
			return Just(nil).eraseToAnyPublisher()
		}
		var request = URLRequest(url: url)
		request.setValue("OilPriceTicker/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
		
		return URLSession.shared.dataTaskPublisher(for: request)
			.handleEvents(receiveSubscription: { _ in
				Self.logger.debug("Starting fetch for symbol \(symbol)")
			})
			.tryMap { data, response in
				if let http = response as? HTTPURLResponse {
					Self.logger.debug("HTTP status: \(http.statusCode)")
				}
				return try Self.decodePrice(from: data)
			}
			.map(Optional.some)
			.replaceError(with: nil)
			.handleEvents(receiveOutput: { price in
				if let p = price {
					Self.logger.debug("Fetched price: \(p)")
				} else {
					if let raw = String(data: (try? JSONSerialization.data(withJSONObject: [:])) ?? Data(), encoding: .utf8) {
						Self.logger.error("Failed to decode price. Raw response: \(raw)")
					} else {
						Self.logger.error("Failed to fetch price")
					}
				}
			})
			.eraseToAnyPublisher()
	}
	
	private func makeURL(symbol: String, fields: String) -> URL? {
		var comps = URLComponents(string: "https://www.barchart.com/proxies/core-api/v1/quotes/get")
		comps?.queryItems = [
			URLQueryItem(name: "symbols", value: symbol),
			URLQueryItem(name: "fields", value: fields)
		]
		return comps?.url
	}
	
	private static func decodePrice(from data: Data) throws -> Double {
		// Log raw JSON for debugging
		if let raw = String(data: data, encoding: .utf8) {
			logger.debug("Raw JSON: \(raw, privacy: .public)")
		}
		struct Response: Decodable {
			struct Quote: Decodable {
				let lastPrice: Double
				
				private enum CodingKeys: String, CodingKey { case lastPrice }
				init(from decoder: Decoder) throws {
					let container = try decoder.container(keyedBy: CodingKeys.self)
					if let doubleVal = try? container.decode(Double.self, forKey: .lastPrice) {
						lastPrice = doubleVal
					} else {
						let stringVal = try container.decode(String.self, forKey: .lastPrice)
						guard let dbl = Double(stringVal) else {
							throw DecodingError.dataCorruptedError(forKey: .lastPrice, in: container, debugDescription: "Cannot convert lastPrice string to Double")
						}
						lastPrice = dbl
					}
				}
			}
			let data: [Quote]
		}
		let decoded = try JSONDecoder().decode(Response.self, from: data)
		guard let price = decoded.data.first?.lastPrice else {
			throw URLError(.cannotParseResponse)
		}
		return price
	}
} 