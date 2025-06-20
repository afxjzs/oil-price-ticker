import Foundation
import Combine
import OSLog

struct EIAJsonPriceFetcher {
	private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OilPriceTicker", category: "EIAJSON")
	private let url = URL(string: "https://api.eia.gov/series/?api_key=DEMO_KEY&series_id=PET.RWTC.D")!
	
	func fetchPrice() -> AnyPublisher<Double?, Never> {
		URLSession.shared.dataTaskPublisher(for: url)
			.map { $0.data }
			.tryMap { data -> Double in
				let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
				guard
					let seriesArr = json?["series"] as? [[String: Any]],
					let firstSeries = seriesArr.first,
					let dataArr = firstSeries["data"] as? [[Any]],
					let firstData = dataArr.first,
					firstData.count >= 2,
					let priceStr = firstData[1] as? String,
					let price = Double(priceStr) else {
					throw URLError(.cannotParseResponse)
				}
				return price
			}
			.map(Optional.some)
			.replaceError(with: nil)
			.handleEvents(receiveOutput: { price in
				if let p = price { Self.logger.debug("EIA JSON price: \(p)") }
				else { Self.logger.error("EIA JSON parse failed") }
			})
			.eraseToAnyPublisher()
	}
} 