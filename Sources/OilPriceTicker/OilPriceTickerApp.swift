import SwiftUI

@main
struct OilPriceTickerApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	
	var body: some Scene {
		Settings {
			PreferencesView()
		}
	}
} 