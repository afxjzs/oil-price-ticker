//OilPriceTicker/PreferencesView.swift
import SwiftUI

struct PreferencesView: View {
	@AppStorage("interval") private var interval: Double = RefreshInterval.default

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Form {
				Picker("Refresh every", selection: $interval) {
					// A value carried over from an older build may not be one of
					// the presets. Offer it as its own row rather than silently
					// snapping it to a neighbour or leaving the Picker blank.
					if !RefreshInterval.presets.contains(interval) {
						Text(RefreshInterval.label(for: interval)).tag(interval)
					}
					ForEach(RefreshInterval.presets, id: \.self) { seconds in
						Text(RefreshInterval.label(for: seconds)).tag(seconds)
					}
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