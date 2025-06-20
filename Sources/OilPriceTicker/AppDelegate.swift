import Cocoa
import Combine
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
	private var statusItem: NSStatusItem!
	private var cancellable: AnyCancellable?
	private let fetcher = BarchartScrapeFetcher()
	private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OilPriceTicker", category: "App")
	private var subscriptions = Set<AnyCancellable>()
	
	func applicationDidFinishLaunching(_ notification: Notification) {
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
		statusItem.button?.title = "⛽︎ ––.–"
		
		startUpdating()
		logger.debug("Application launched, starting updates")
	}
	
	private func startUpdating() {
		let interval = UserDefaults.standard.double(forKey: "interval")
		let refresh = interval == 0 ? 60 : interval
		logger.debug("Refresh interval set to \(refresh, privacy: .public) seconds")
		
		// First fetch immediately
		fetchAndDisplay()
		
		// Schedule subsequent fetches
		cancellable = Timer
			.publish(every: refresh, on: .main, in: .common)
			.autoconnect()
			.sink { [weak self] _ in
				self?.fetchAndDisplay()
			}
	}
	
	private func fetchAndDisplay() {
		fetcher.fetchPrice()
			.receive(on: DispatchQueue.main)
			.sink { [weak self] price in
				guard let self, let button = self.statusItem.button else { return }
				if let price {
					button.title = String(format: "⛽ $%.2f", price)
					logger.debug("Updated UI with price: \(price)")
				} else {
					button.title = "⛽︎ ––.–"
					logger.error("Price nil; UI shows placeholder")
				}
			}
			.store(in: &subscriptions)
	}
} 