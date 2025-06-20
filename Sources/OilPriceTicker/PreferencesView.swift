import SwiftUI

struct PreferencesView: View {
	@AppStorage("interval") private var interval: Double = 60
	
	var body: some View {
		Form {
			Stepper(value: $interval, in: 30...600, step: 5) {
				Text("Refresh every \(Int(interval)) s")
			}
		}
		.padding()
		.frame(width: 300)
	}
}

#Preview {
	PreferencesView()
} 