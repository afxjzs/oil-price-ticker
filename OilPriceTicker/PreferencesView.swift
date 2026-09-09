//OilPriceTicker/PreferencesView.swift
import SwiftUI

struct PreferencesView: View {
	@AppStorage("interval") private var interval: Double = 60
	
	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Form {
				Stepper(value: $interval, in: 30...600, step: 5) {
					Text("Refresh every \(Int(interval)) s")
				}
			}
			
			Divider()
			
			VStack(alignment: .leading, spacing: 8) {
				Text("Launch at Login")
					.font(.headline)
				Text("To run OilPriceTicker at startup:")
					.font(.caption)
					.foregroundColor(.secondary)
				Text("• System Preferences → Users & Groups → Login Items")
					.font(.caption)
					.foregroundColor(.secondary)
				Text("• Click '+' and add OilPriceTicker.app")
					.font(.caption)
					.foregroundColor(.secondary)
			}
		}
		.padding()
		.frame(width: 320)
	}
}

#Preview {
	PreferencesView()
} 