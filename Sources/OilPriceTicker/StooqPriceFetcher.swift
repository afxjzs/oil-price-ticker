import Foundation
import Combine
import OSLog

struct StooqPriceFetcher {
	private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OilPriceTicker", category: "StooqNetwork")
	
	/// Attempt multiple symbols
	func fetchPrice(symbols: [String] = ["wti", "cl=f"]) -> AnyPublisher<Double?, Never> {
		let publishers = symbols.publisher.flatMap { self.singleFetch(symbol: $0) }
		return publishers
			.first { $0 != nil }
			.eraseToAnyPublisher()
	}
	
	private func singleFetch(symbol: String) -> AnyPublisher<Double?, Never> {
		guard let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
			  let url = URL(string: "https://stooq.com/q/l/?s=\(encoded)&f=sd2t2ohlcv&h&e=csv") else {
			return Just(nil).eraseToAnyPublisher()
		}
		return URLSession.shared.dataTaskPublisher(for: url)
			.map { $0.data }
			.tryMap { data -> Double in
				guard let csv = String(data: data, encoding: .utf8) else {
					throw URLError(.cannotParseResponse)
				}
				Self.logger.debug("CSV for \(symbol): \(csv, privacy: .public)")
				let rows = csv.components(separatedBy: "\n").filter { !$0.isEmpty }
				guard rows.count >= 2 else { throw URLError(.cannotParseResponse) }
				let cols = rows[1].split(separator: ",")
				guard cols.count >= 7, let price = Double(cols[6]), price > 0 else {
					throw URLError(.cannotParseResponse)
				}
				return price
			}
			.map(Optional.some)
			.replaceError(with: nil)
			.eraseToAnyPublisher()
	}
} 