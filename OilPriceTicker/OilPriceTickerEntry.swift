//OilPriceTicker/OilPriceTickerEntry.swift
import SwiftUI

struct OilPriceTickerEntry: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	var body: some Scene {
		Settings {
			PreferencesView()
		}
	}
} 