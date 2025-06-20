import Cocoa
import Combine
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
	private var statusItem: NSStatusItem!
	private var cancellable: AnyCancellable?
	private let fetcher = BarchartScrapeFetcher()
	private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OilPriceTicker", category: "App")
	private var subscriptions = Set<AnyCancellable>()
	private let statusMenu = NSMenu()
	
	func applicationDidFinishLaunching(_ notification: Notification) {
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
		
		// Set barrel emoji as icon image
		statusItem.button?.image = Self.emojiImage("🛢️")
		statusItem.button?.imagePosition = .imageLeft
		statusItem.button?.title = " ––.–" // leading space to separate icon and price
		
		startUpdating()
		logger.debug("Application launched, starting updates")
		setupMenu()
		if let button = statusItem.button {
			button.target = self
			button.action = #selector(handleStatusItemClick(_:))
			button.sendAction(on: [.leftMouseUp, .rightMouseUp])
		}
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
					button.title = String(format: " $%.2f", price)
					logger.debug("Updated UI with price: \(price)")
				} else {
					button.title = " ––.–"
					logger.error("Price nil; UI shows placeholder")
				}
			}
			.store(in: &subscriptions)
	}
	
	// MARK: – Menu
	private func setupMenu() {
		statusMenu.autoenablesItems = false
		statusMenu.delegate = self
		statusMenu.addItem(NSMenuItem(title: "About OilPriceTicker", action: #selector(showAbout), keyEquivalent: ""))
		statusMenu.addItem(NSMenuItem.separator())
		statusMenu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
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
	
	@objc private func quitApp() {
		NSApp.terminate(nil)
	}
	
	// Create NSImage from emoji string
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