//OilPriceTicker/PriceFetcher.swift
import Foundation
import Combine
import OSLog

/// One successful quote, carrying its own provenance.
///
/// `source` and `fetchedAt` travel with the price on purpose: the UI must always
/// be able to say where a number came from and how old it is, rather than
/// showing a bare figure the user has to trust blindly.
struct OilQuote {
	let price: Double
	/// Barchart-style contract label from the feed, e.g. "Crude Oil Oct 26".
	let contract: String?
	let changePercent: Double?
	/// Host that actually answered, so a fallback is never invisible.
	let source: String
	let fetchedAt: Date
}

/// Every way a fetch can fail, kept distinct so the status item can show the
/// real reason instead of a generic placeholder.
enum PriceFetchError: LocalizedError {
	case badURL(String)
	case transport(host: String, detail: String)
	case http(host: String, status: Int)
	case emptyBody(host: String)
	case malformed(host: String, detail: String)
	case feedError(host: String, detail: String)
	/// Every source was tried and each one failed; carries per-host reasons.
	case allSourcesFailed([(host: String, reason: String)])

	var errorDescription: String? {
		switch self {
		case .badURL(let url):
			return "Could not build request URL: \(url)"
		case .transport(let host, let detail):
			return "\(host): network error — \(detail)"
		case .http(let host, let status):
			return "\(host): HTTP \(status)"
		case .emptyBody(let host):
			return "\(host): empty response body"
		case .malformed(let host, let detail):
			return "\(host): unexpected response — \(detail)"
		case .feedError(let host, let detail):
			return "\(host): feed reported — \(detail)"
		case .allSourcesFailed(let failures):
			let lines = failures.map { "\($0.host): \($0.reason)" }.joined(separator: "; ")
			return "All sources failed — \(lines)"
		}
	}
}

/// Fetches the WTI crude front-month price from Yahoo Finance's chart endpoint.
///
/// Replaces the previous Barchart HTML scrape, which stopped working when
/// Barchart put the quote pages behind a bot wall: every request now returns
/// HTTP 202 with a zero-byte body regardless of User-Agent, so there is no
/// markup left to parse.
///
/// The symbol `CL=F` is Yahoo's *continuous* front-month contract, so it rolls
/// to the next month on its own — no hardcoded expiry to go stale, which is the
/// second failure this app has already had.
struct PriceFetcher {
	private static let logger = Logger(
		subsystem: Bundle.main.bundleIdentifier ?? "OilPriceTicker",
		category: "PriceFetcher"
	)

	/// WTI crude, continuous front month.
	private let symbol = "CL=F"

	/// Tried in order. Both are the same Yahoo API on different edge hosts;
	/// when one throttles, the other often still answers.
	private let hosts = ["query1.finance.yahoo.com", "query2.finance.yahoo.com"]

	/// Yahoo returns HTTP 429 to requests that do not look like a browser.
	/// This is required, not cosmetic.
	private static let userAgent =
		"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
		+ "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36"

	private let session: URLSession

	init(session: URLSession = .shared) {
		self.session = session
	}

	/// Emits exactly one `Result` and completes. Never fails, but never silently
	/// swallows a failure either — the error case carries the reason for display.
	func fetchQuote() -> AnyPublisher<Result<OilQuote, PriceFetchError>, Never> {
		attempt(hostIndex: 0, failures: [])
	}

	/// Walks the host list, collecting each failure so the last one can report
	/// all of them rather than just whichever happened to be last.
	private func attempt(
		hostIndex: Int,
		failures: [(host: String, reason: String)]
	) -> AnyPublisher<Result<OilQuote, PriceFetchError>, Never> {
		guard hostIndex < hosts.count else {
			let error = PriceFetchError.allSourcesFailed(failures)
			Self.logger.error("All sources failed: \(error.localizedDescription, privacy: .public)")
			return Just(.failure(error)).eraseToAnyPublisher()
		}

		let host = hosts[hostIndex]
		guard let url = Self.makeURL(host: host, symbol: symbol) else {
			let error = PriceFetchError.badURL("\(host)/\(symbol)")
			Self.logger.error("\(error.localizedDescription, privacy: .public)")
			return Just(.failure(error)).eraseToAnyPublisher()
		}

		var request = URLRequest(url: url)
		request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		request.timeoutInterval = 15

		return session.dataTaskPublisher(for: request)
			.mapError { PriceFetchError.transport(host: host, detail: $0.localizedDescription) }
			.tryMap { data, response -> OilQuote in
				try Self.parse(data: data, response: response, host: host)
			}
			.mapError { error -> PriceFetchError in
				// tryMap widens the error type; recover the specific case.
				(error as? PriceFetchError)
					?? .malformed(host: host, detail: error.localizedDescription)
			}
			.map { Result<OilQuote, PriceFetchError>.success($0) }
			.catch { (error: PriceFetchError) -> AnyPublisher<Result<OilQuote, PriceFetchError>, Never> in
				let reason = error.errorDescription ?? "unknown"
				Self.logger.error("Source \(host, privacy: .public) failed: \(reason, privacy: .public)")
				let collected = failures + [(host: host, reason: reason)]

				// A rate limit is a request to send *less* traffic. Yahoo throttles
				// per client across both edge hosts, so cascading to the next one
				// would double our rate at the exact moment we are being told to
				// slow down, and deepen the block. Give up this cycle instead and
				// let the caller's backoff handle it.
				if Self.isRateLimit(error) {
					Self.logger.error("Rate limited by \(host, privacy: .public); not trying remaining hosts this cycle")
					return Just(.failure(.allSourcesFailed(collected))).eraseToAnyPublisher()
				}

				return attempt(hostIndex: hostIndex + 1, failures: collected)
			}
			.handleEvents(receiveOutput: { result in
				if case .success(let quote) = result {
					Self.logger.debug(
						"""
						Quote \(quote.price, privacy: .public) \
						(\(quote.contract ?? "unknown contract", privacy: .public)) \
						from \(quote.source, privacy: .public)
						"""
					)
				}
			})
			.eraseToAnyPublisher()
	}

	/// True when the failure means "you are sending too much", so the right
	/// response is to wait rather than to retry elsewhere.
	static func isRateLimit(_ error: PriceFetchError) -> Bool {
		switch error {
		case .http(_, let status):
			return status == 429
		case .allSourcesFailed(let failures):
			return failures.contains { $0.reason.contains("HTTP 429") }
		default:
			return false
		}
	}

	private static func makeURL(host: String, symbol: String) -> URL? {
		var components = URLComponents()
		components.scheme = "https"
		components.host = host
		components.path = "/v8/finance/chart/\(symbol)"
		components.queryItems = [
			URLQueryItem(name: "interval", value: "1d"),
			URLQueryItem(name: "range", value: "1d")
		]
		return components.url
	}

	/// Internal rather than private so tests can exercise it directly against
	/// captured payloads, without depending on a live (and rate-limited) network.
	static func parse(data: Data, response: URLResponse, host: String) throws -> OilQuote {
		if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
			throw PriceFetchError.http(host: host, status: http.statusCode)
		}
		guard !data.isEmpty else {
			// Exactly how Barchart failed. Catch it explicitly so the same
			// silent-blank failure can never recur unexplained.
			throw PriceFetchError.emptyBody(host: host)
		}

		let payload: YahooChartResponse
		do {
			payload = try JSONDecoder().decode(YahooChartResponse.self, from: data)
		} catch {
			let preview = String(data: data.prefix(120), encoding: .utf8) ?? "<non-UTF8>"
			throw PriceFetchError.malformed(host: host, detail: "not JSON (\(preview))")
		}

		if let feedError = payload.chart.error {
			throw PriceFetchError.feedError(
				host: host,
				detail: feedError.description ?? feedError.code ?? "unspecified"
			)
		}
		guard let meta = payload.chart.result?.first?.meta else {
			throw PriceFetchError.malformed(host: host, detail: "no result entry")
		}
		guard let price = meta.regularMarketPrice else {
			throw PriceFetchError.malformed(host: host, detail: "no regularMarketPrice")
		}

		return OilQuote(
			price: price,
			contract: meta.shortName,
			changePercent: meta.regularMarketChangePercent,
			source: host,
			fetchedAt: Date()
		)
	}
}

// MARK: - Yahoo response shape

private struct YahooChartResponse: Decodable {
	let chart: Chart

	struct Chart: Decodable {
		let result: [ChartResult]?
		let error: FeedError?
	}

	struct ChartResult: Decodable {
		let meta: Meta
	}

	struct Meta: Decodable {
		let regularMarketPrice: Double?
		let shortName: String?
		let regularMarketChangePercent: Double?
	}

	struct FeedError: Decodable {
		let code: String?
		let description: String?
	}
}
