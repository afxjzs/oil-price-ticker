//OilPriceTicker/PriceFetcher.swift
import Foundation
import Combine
import OSLog

/// One quote from the relay, carrying its own provenance.
///
/// `source`, `quoteTime` and `fetchedAt` travel with the price on purpose: the
/// UI must always be able to say where a number came from and how old it is,
/// rather than showing a bare figure the user has to trust blindly.
struct OilQuote {
	let price: Double
	/// Contract label from the upstream source, e.g. "CLX26" or "Crude Oil Nov 26".
	let contract: String?
	let changePercent: Double?
	/// Upstream site the relay got the price from, e.g. "yahoo".
	let source: String
	/// When the exchange quoted this price, if the source said.
	let quoteTime: Date?
	/// When the relay fetched it.
	let fetchedAt: Date
	/// Set when the relay's most recent run failed on every source, so the
	/// price is a held-over one. Lists each source's reason.
	let relayFailure: String?
}

/// Every way a fetch can fail, kept distinct so the status item can show the
/// real reason instead of a generic placeholder.
enum PriceFetchError: LocalizedError {
	case transport(host: String, detail: String)
	case http(host: String, status: Int)
	case emptyBody(host: String)
	case malformed(host: String, detail: String)
	/// The relay answered but has never managed to fetch a price.
	case relayHasNoQuote(host: String, detail: String)

	var errorDescription: String? {
		switch self {
		case .transport(let host, let detail):
			return "\(host): network error — \(detail)"
		case .http(let host, let status):
			return "\(host): HTTP \(status)"
		case .emptyBody(let host):
			return "\(host): empty response body"
		case .malformed(let host, let detail):
			return "\(host): unexpected response — \(detail)"
		case .relayHasNoQuote(let host, let detail):
			return "\(host): no price yet — \(detail)"
		}
	}
}

/// Fetches the WTI crude front-month price from the WTI relay, a Cloudflare
/// Worker (source in `relay/`) that polls the quote sites every 5 minutes.
///
/// The app used to call Yahoo Finance directly, and before that scraped
/// Barchart. Both failures came from the same place: every copy of the app
/// polled a quote site from its own address, and the sites block or rate limit
/// per address. The relay is one poller for everyone and tries several sources.
struct PriceFetcher {
	private static let logger = Logger(
		subsystem: Bundle.main.bundleIdentifier ?? "OilPriceTicker",
		category: "PriceFetcher"
	)

	static let relayURL = URL(string: "https://wti.oil-price.workers.dev/")!

	private let session: URLSession

	init(session: URLSession = .shared) {
		self.session = session
	}

	/// Emits exactly one `Result` and completes. Never fails, but never silently
	/// swallows a failure either: the error case carries the reason for display.
	func fetchQuote() -> AnyPublisher<Result<OilQuote, PriceFetchError>, Never> {
		let url = Self.relayURL
		let host = url.host ?? url.absoluteString
		var request = URLRequest(url: url)
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
			.catch { (error: PriceFetchError) -> Just<Result<OilQuote, PriceFetchError>> in
				Self.logger.error("Fetch failed: \(error.localizedDescription, privacy: .public)")
				return Just(.failure(error))
			}
			.handleEvents(receiveOutput: { result in
				if case .success(let quote) = result {
					Self.logger.debug(
						"Quote \(quote.price, privacy: .public) from \(quote.source, privacy: .public) via relay"
					)
				}
			})
			.eraseToAnyPublisher()
	}

	/// Internal rather than private so tests can exercise it directly against
	/// captured payloads, without depending on the live relay.
	static func parse(data: Data, response: URLResponse, host: String) throws -> OilQuote {
		guard let status = (response as? HTTPURLResponse)?.statusCode else {
			throw PriceFetchError.malformed(host: host, detail: "not an HTTP response")
		}
		let decoded = Result { try JSONDecoder().decode(RelayResponse.self, from: data) }
		let payload = try? decoded.get()

		// Before its first good run the relay answers 503 with an explanation.
		if status == 503, let payload, payload.quote == nil {
			throw PriceFetchError.relayHasNoQuote(host: host, detail: payload.explanation)
		}
		guard (200...299).contains(status) else {
			throw PriceFetchError.http(host: host, status: status)
		}
		guard !data.isEmpty else {
			// Exactly how Barchart failed. Catch it explicitly so the same
			// silent-blank failure can never recur unexplained.
			throw PriceFetchError.emptyBody(host: host)
		}
		guard let payload else {
			let preview = String(data: data.prefix(120), encoding: .utf8) ?? "<non-UTF8>"
			var reason = "unknown"
			if case .failure(let error) = decoded { reason = String(describing: error) }
			throw PriceFetchError.malformed(host: host, detail: "not relay JSON: \(reason) (\(preview))")
		}
		guard let quote = payload.quote else {
			throw PriceFetchError.relayHasNoQuote(host: host, detail: payload.explanation)
		}
		guard let price = quote.price, price.isFinite, price > 0 else {
			throw PriceFetchError.malformed(host: host, detail: "no usable price (\(quote.price.map { "\($0)" } ?? "missing"))")
		}
		guard let fetchedAtText = payload.fetchedAt, let fetchedAt = parseDate(fetchedAtText) else {
			throw PriceFetchError.malformed(host: host, detail: "bad fetchedAt (\(payload.fetchedAt ?? "missing"))")
		}
		var quoteTime: Date?
		if let text = quote.quoteTime {
			// Present but unreadable is a fault, not the same as "the source gave no time".
			guard let parsed = parseDate(text) else {
				throw PriceFetchError.malformed(host: host, detail: "bad quoteTime (\(text))")
			}
			quoteTime = parsed
		}

		return OilQuote(
			price: price,
			contract: quote.contract,
			changePercent: quote.changePercent,
			source: quote.source ?? "unknown",
			quoteTime: quoteTime,
			fetchedAt: fetchedAt,
			relayFailure: payload.lastAttempt?.ok == false ? payload.lastAttempt?.failureSummary : nil
		)
	}

	private static func parseDate(_ text: String) -> Date? {
		let withFraction = ISO8601DateFormatter()
		withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
	}
}

// MARK: - Relay response shape (see relay/README.md)

private struct RelayResponse: Decodable {
	let quote: Quote?
	let fetchedAt: String?
	let lastAttempt: Attempt?
	let error: String?

	struct Quote: Decodable {
		let price: Double?
		let changePercent: Double?
		let contract: String?
		let quoteTime: String?
		let source: String?
	}

	struct Attempt: Decodable {
		let at: String
		let ok: Bool
		let failures: [Failure]

		var failureSummary: String {
			"relay's last run failed: " + failures.map { "\($0.source): \($0.reason)" }.joined(separator: "; ")
		}
	}

	struct Failure: Decodable {
		let source: String
		let reason: String
	}

	/// The relay's own account of why it has no price.
	var explanation: String {
		let failures = lastAttempt.map { $0.failureSummary }
		let parts = [error, failures].compactMap { $0 }
		return parts.isEmpty ? "the relay gave no reason" : parts.joined(separator: "; ")
	}
}
