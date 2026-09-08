import Cocoa
import Combine
import OSLog
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
	private var statusItem: NSStatusItem!
	private let fetcher = PriceFetcher()
	private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OilPriceTicker", category: "App")
	private var subscriptions = Set<AnyCancellable>()
	private let statusMenu = NSMenu()
	private var prefsWindow: NSWindow?

	/// Shown while no price has ever been fetched.
	private static let placeholder = "🛢️ ––.–"

	/// Last price we actually got. Kept across failures so a blip does not blank
	/// the display — but see `lastError`: a retained price is always marked stale
	/// rather than passed off as current.
	private var lastQuote: OilQuote?
	/// Failure from the most recent attempt, or nil if that attempt succeeded.
	private var lastError: PriceFetchError?
	private var lastAttemptAt: Date?

	private lazy var statusLineItem: NSMenuItem = {
		let item = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
		item.isEnabled = false
		return item
	}()

	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.setActivationPolicy(.accessory)
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
		statusItem.button?.title = Self.placeholder
		statusItem.button?.toolTip = "OilPriceTicker: starting up…"
		startUpdating()
		logger.debug("Application launched, starting updates")
		setupMenu()
		if let button = statusItem.button {
			button.target = self
			button.action = #selector(handleStatusItemClick(_:))
			button.sendAction(on: [.leftMouseUp, .rightMouseUp])
		}
	}

	/// User's configured gap between polls, in seconds.
	private var baseInterval: TimeInterval {
		let stored = UserDefaults.standard.double(forKey: "interval")
		return stored == 0 ? 60 : stored
	}

	/// Never back off further than this, so the ticker always recovers on its own.
	private static let maxBackoff: TimeInterval = 15 * 60

	private var consecutiveFailures = 0
	private var refreshTimer: Timer?
	private var nextFetchAt: Date?

	private func startUpdating() {
		logger.debug("Base refresh interval \(self.baseInterval, privacy: .public)s")
		fetchAndDisplay()
	}

	/// Interval to wait before the next attempt. Doubles per consecutive failure
	/// so a rate limit or outage is not made worse by polling straight through it.
	private func nextDelay() -> TimeInterval {
		guard consecutiveFailures > 0 else { return baseInterval }
		let scaled = baseInterval * pow(2, Double(consecutiveFailures))
		return min(scaled, Self.maxBackoff)
	}

	private func scheduleNextFetch() {
		refreshTimer?.invalidate()
		let delay = nextDelay()
		nextFetchAt = Date().addingTimeInterval(delay)
		if consecutiveFailures > 0 {
			logger.debug("Backing off \(delay, privacy: .public)s after \(self.consecutiveFailures, privacy: .public) failures")
		}
		let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
			self?.fetchAndDisplay()
		}
		RunLoop.main.add(timer, forMode: .common)
		refreshTimer = timer
	}

	private func fetchAndDisplay() {
		fetcher.fetchQuote()
			.receive(on: DispatchQueue.main)
			.sink { [weak self] result in
				guard let self else { return }
				self.lastAttemptAt = Date()
				switch result {
				case .success(let quote):
					self.lastQuote = quote
					self.lastError = nil
					self.consecutiveFailures = 0
					self.logger.debug("Updated UI with price: \(quote.price, privacy: .public)")
				case .failure(let error):
					self.lastError = error
					self.consecutiveFailures += 1
					self.logger.error("Fetch failed: \(error.localizedDescription, privacy: .public)")
				}
				self.render()
				self.scheduleNextFetch()
			}
			.store(in: &subscriptions)
	}

	/// Single place that decides what the menu bar shows, so the title, tooltip
	/// and menu can never disagree about whether the price is current.
	private func render() {
		guard let button = statusItem.button else { return }

		if let quote = lastQuote {
			let stale = lastError != nil
			// A retained price is visibly flagged. Showing yesterday's number as
			// though it were live is the failure mode this marker exists to stop.
			button.title = String(format: "🛢️ $%.2f%@", quote.price, stale ? " ⚠︎" : "")
		} else {
			button.title = Self.placeholder
		}

		button.toolTip = statusSummary()
		statusLineItem.title = statusLine()
	}

	/// One-line status for the menu.
	private func statusLine() -> String {
		if let error = lastError {
			let base = lastQuote == nil
				? "No price — fetch failing (\(shortReason(error)))"
				: "Stale — last refresh failed (\(shortReason(error)))"
			return base + retrySuffix()
		}
		guard let quote = lastQuote else { return "Starting…" }
		return "Live — \(quote.contract ?? "WTI front month")"
	}

	/// Says when the next attempt happens, so a long backoff is never mistaken
	/// for the app having quietly given up.
	private func retrySuffix() -> String {
		guard consecutiveFailures > 0, let next = nextFetchAt else { return "" }
		let seconds = max(0, Int(next.timeIntervalSinceNow.rounded()))
		return seconds >= 60
			? ", retry in \(seconds / 60)m \(seconds % 60)s"
			: ", retry in \(seconds)s"
	}

	/// Full multi-line status for the tooltip: what the number is, where it came
	/// from, when it arrived, and what went wrong if anything did.
	private func statusSummary() -> String {
		var lines: [String] = []

		if let quote = lastQuote {
			lines.append(String(format: "WTI front month: $%.2f", quote.price))
			if let contract = quote.contract { lines.append("Contract: \(contract)") }
			if let change = quote.changePercent {
				lines.append(String(format: "Change: %+.2f%%", change))
			}
			lines.append("Source: \(quote.source)")
			lines.append("Updated: \(Self.timeFormatter.string(from: quote.fetchedAt))")
		} else {
			lines.append("No price fetched yet.")
		}

		if let error = lastError {
			lines.append("")
			lines.append("Last attempt FAILED\(lastAttemptAt.map { " at \(Self.timeFormatter.string(from: $0))" } ?? ""):")
			lines.append(error.localizedDescription)
			if lastQuote != nil {
				lines.append("Showing last known price (marked ⚠︎).")
			}
			lines.append("Consecutive failures: \(consecutiveFailures)")
			if let next = nextFetchAt {
				lines.append("Next attempt: \(Self.timeFormatter.string(from: next))")
			}
		}

		return lines.joined(separator: "\n")
	}

	private func shortReason(_ error: PriceFetchError) -> String {
		switch error {
		case .badURL: return "bad URL"
		case .transport: return "network"
		case .http(_, let status): return "HTTP \(status)"
		case .emptyBody: return "empty response"
		case .malformed: return "bad response"
		case .feedError: return "feed error"
		case .allSourcesFailed: return "all sources down"
		}
	}

	private static let timeFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateStyle = .none
		formatter.timeStyle = .medium
		return formatter
	}()

	// MARK: – Menu
	private func setupMenu() {
		statusMenu.autoenablesItems = false
		statusMenu.delegate = self
		statusMenu.addItem(statusLineItem)
		statusMenu.addItem(NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r"))
		statusMenu.addItem(NSMenuItem.separator())
		statusMenu.addItem(NSMenuItem(title: "Preferences…", action: #selector(showPreferences), keyEquivalent: ","))
		statusMenu.addItem(NSMenuItem.separator())
		statusMenu.addItem(NSMenuItem(title: "About OilPriceTicker", action: #selector(showAbout), keyEquivalent: ""))
		statusMenu.addItem(NSMenuItem.separator())
		statusMenu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
	}

	func menuNeedsUpdate(_ menu: NSMenu) {
		statusLineItem.title = statusLine()
	}

	@objc private func refreshNow() {
		logger.debug("Manual refresh requested")
		fetchAndDisplay()
	}

	@objc private func handleStatusItemClick(_ sender: Any?) {
		guard let event = NSApp.currentEvent else { return }
		if event.type == .rightMouseUp {
			statusItem.menu = statusMenu
			statusItem.button?.performClick(nil)
		}
	}

	func menuDidClose(_ menu: NSMenu) {
		statusItem.menu = nil
	}

	@objc private func showAbout() {
		let alert = NSAlert()
		alert.messageText = "OilPriceTicker"
		alert.informativeText = "Made by Douglas E. Rogers\nReleased under the MIT License."
		let linkField = NSTextField(labelWithAttributedString: linkAttr())
		linkField.isSelectable = true
		alert.accessoryView = linkField
		alert.addButton(withTitle: "OK")
		alert.icon = Self.emojiImage("🛢️")
		alert.runModal()
	}

	private func linkAttr() -> NSAttributedString {
		let url = URL(string: "https://doug.is")!
		let attrs: [NSAttributedString.Key: Any] = [
			.link: url,
			.foregroundColor: NSColor.systemBlue,
			.underlineStyle: NSUnderlineStyle.single.rawValue
		]
		return NSAttributedString(string: "https://doug.is", attributes: attrs)
	}

	@objc private func quitApp() { NSApp.terminate(nil) }

	@objc private func showPreferences() {
		if prefsWindow == nil {
			let hosting = NSHostingController(rootView: PreferencesView())
			let window = NSWindow(contentViewController: hosting)
			window.title = "Preferences"
			window.styleMask = [.titled, .closable]
			window.isReleasedWhenClosed = false
			window.setContentSize(NSSize(width: 320, height: 120))
			window.center()
			prefsWindow = window
		}
		prefsWindow?.makeKeyAndOrderFront(nil)
		prefsWindow?.orderFrontRegardless()
		NSApp.activate(ignoringOtherApps: true)
	}

	private static func emojiImage(_ emoji: String) -> NSImage? {
		let size = NSSize(width: 18, height: 18)
		let image = NSImage(size: size)
		image.lockFocus()
		(emoji as NSString).draw(in: NSRect(origin: .zero, size: size), withAttributes: [.font: NSFont.systemFont(ofSize: 16)])
		image.unlockFocus()
		image.isTemplate = false
		return image
	}
}
