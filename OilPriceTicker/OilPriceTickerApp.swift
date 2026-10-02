//OilPriceTicker/OilPriceTickerApp.swift
//
//  OilPriceTickerApp.swift
//  OilPriceTicker
//
//  Created by Douglas Rogers on 6/23/25.
//

import SwiftUI

@main
struct OilPriceTickerShellApp: App {
	// The delegate adaptor sits on the @main App itself. It used to sit on a
	// nested App whose body this one borrowed. AppDelegate creates the menu bar
	// item and runs the fetching.
	@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

	var body: some Scene {
		Settings {
			PreferencesView()
		}
	}
}
