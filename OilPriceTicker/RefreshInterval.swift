//OilPriceTicker/RefreshInterval.swift
import Foundation

/// The refresh interval's allowed range and default, in seconds.
///
/// Kept in one place because the value is read in two: AppDelegate schedules
/// against it and PreferencesView edits it. When those two carried their own
/// copies of the default, changing one silently left the other behind.
enum RefreshInterval {
	/// Oil does not move fast enough to justify polling harder than this, and
	/// a gentle interval keeps well clear of the quote API's rate limiting.
	static let `default`: TimeInterval = 15 * 60

	static let minimum: TimeInterval = 60
	static let maximum: TimeInterval = 60 * 60

	/// Offered in Preferences. A short list of sensible choices beats a stepper
	/// here: reaching 15 minutes from 90 seconds took fourteen clicks.
	static let presets: [TimeInterval] = [60, 120, 300, 600, 900, 1800, 3600]

	/// "15 min", "90 sec" — used for the Preferences label.
	static func label(for seconds: TimeInterval) -> String {
		let whole = Int(seconds.rounded())
		if whole < 60 { return "\(whole) sec" }
		if whole % 60 == 0 { return "\(whole / 60) min" }
		return String(format: "%d min %d sec", whole / 60, whole % 60)
	}
}
