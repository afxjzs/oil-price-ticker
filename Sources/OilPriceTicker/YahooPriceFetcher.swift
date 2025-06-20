import Foundation
import Combine
import OSLog

struct YahooPriceFetcher {
	private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OilPriceTicker", category: "YahooNetwork")
	
	/// Fetch WTI (CL=F) last price from Yahoo Finance quote API.
	func fetchPrice(symbol: String = "CL=F") -> AnyPublisher<Double?, Never> {
		guard let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
			  let url = URL(string: "https://query1.finance.yahoo.com/v7/finance/quote?symbols=\(encoded)") else {
			return Just(nil).eraseToAnyPublisher()
		}
	
		return URLSession.shared.dataTaskPublisher(for: url)
			.mapError { error -> Error in
				Self.logger.error("Network error: \(error.localizedDescription, privacy: .public)")
				return error
			}
			.tryMap { data, response in
				if let http = response as? HTTPURLResponse {
					Self.logger.debug("HTTP status: \(http.statusCode)")
				}
				return try Self.decodePrice(from: data)
			}
			.map(Optional.some)
			.replaceError(with: nil)
			.eraseToAnyPublisher()
	}
	


	
	private static func decodePrice(from data: Data) throws -> Double {
		struct QuoteResponse: Decodable {
			struct Result: Decodable { let regularMarketPrice: Double }
			let result: [Result]
		}
		struct Wrapper: Decodable { let quoteResponse: QuoteResponse }
		let wrapper = try JSONDecoder().decode(Wrapper.self, from: data)
		guard let price = wrapper.quoteResponse.result.first?.regularMarketPrice else {
			throw URLError(.cannotParseResponse)
		}
		logger.debug("Yahoo price decoded: \(price)")
		return price
	}
} 