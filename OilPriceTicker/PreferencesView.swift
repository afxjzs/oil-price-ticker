//OilPriceTicker/PreferencesView.swift
import SwiftUI
import ServiceManagement

struct PreferencesView: View {
	@AppStorage("interval") private var interval: Double = 60
	@State private var launchAtLogin = false
	var body: some View {
		Form {
			Stepper(value: $interval, in: 30...600, step: 5) {
				Text("Refresh every \(Int(interval)) s")
			}
			if #available(macOS 13.0, *) {
				Toggle("Launch at login", isOn: $launchAtLogin)
					.onChange(of: launchAtLogin) { newValue in
						if newValue {
							try? SMAppService.mainApp.register()
						} else {
							try? SMAppService.mainApp.unregister()
						}
					}
			}
		}
		.padding()
		.frame(width: 300)
		.onAppear {
			if #available(macOS 13.0, *) {
				launchAtLogin = SMAppService.mainApp.status == .enabled
			}
		}
	}
}

#Preview {
	PreferencesView()
} 