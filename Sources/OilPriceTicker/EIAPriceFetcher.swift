import Foundation
import Combine
import OSLog

struct EIAPriceFetcher {
	private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OilPriceTicker", category: "EIANetwork")
	private let url = URL(string: "https://datahub.io/core/oil-prices/r/wti-daily.csv")!
	
	func fetchPrice() -> AnyPublisher<Double?, Never> {
		URLSession.shared.dataTaskPublisher(for: url)
			.map { $0.data }
			.tryMap { data -> Double in
				guard let csv = String(data: data, encoding: .utf8) else { throw URLError(.cannotParseResponse) }
				let rows = csv.components(separatedBy: "\n").reversed()
				for row in rows {
					let cols = row.split(separator: ",")
					guard cols.count == 2 else { continue }
					if let price = Double(cols[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))) {
						return price
					}
				}
				throw URLError(.cannotParseResponse)
			}
			.map(Optional.some)
			.replaceError(with: nil)
			.handleEvents(receiveOutput: { price in
				if let p = price { Self.logger.debug("EIA price: \(p)") }
			else { Self.logger.error("EIA parse failed") }
			})
			.eraseToAnyPublisher()
	}
} 