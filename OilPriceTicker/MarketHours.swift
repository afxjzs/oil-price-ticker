//OilPriceTicker/MarketHours.swift
import Foundation

/// CME Globex trading hours for WTI crude futures: Sunday 6pm to Friday 5pm
/// New York time, with a one-hour break from 5pm each weekday.
///
/// Exchange holidays are not modeled. On one, the quote stops moving while
/// this says the market is open, so the price shows as stale (⚠︎) rather than
/// closed. That errs toward a false warning, never toward a false "live".
enum MarketHours {
	private static let calendar: Calendar = {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone(identifier: "America/New_York")!
		return calendar
	}()

	/// Weekday numbers in `Calendar`: 1 is Sunday, 7 is Saturday.
	private static let sunday = 1, friday = 6, saturday = 7
	private static let breakStartHour = 17, openHour = 18

	static func isOpen(_ date: Date) -> Bool {
		let weekday = calendar.component(.weekday, from: date)
		let hour = calendar.component(.hour, from: date)
		switch weekday {
		case saturday: return false
		case sunday: return hour >= openHour
		case friday: return hour < breakStartHour
		default: return hour < breakStartHour || hour >= openHour
		}
	}

	/// When the current trading session began: the most recent 6pm New York
	/// time at or before `date`. Only meaningful while the market is open.
	static func sessionStart(containing date: Date) -> Date {
		let sixPMToday = calendar.date(bySettingHour: openHour, minute: 0, second: 0, of: date)!
		if sixPMToday <= date { return sixPMToday }
		return calendar.date(byAdding: .day, value: -1, to: sixPMToday)!
	}
}

/// Whether a quote is current, judged by its age against the trading schedule.
enum Freshness: Equatable {
	/// The market is open and the quote is recent enough.
	case live
	/// The market is closed, so an old quote is expected.
	case closed
	/// The market is open but the quote is too old: something upstream is stuck.
	case stale

	/// Free sources run about 10 minutes behind and the relay polls every 5,
	/// so a healthy quote is under about 15 minutes old. Twice that is a fault.
	static let maxAge: TimeInterval = 30 * 60

	static func evaluate(quoteTime: Date, now: Date) -> Freshness {
		guard MarketHours.isOpen(now) else { return .closed }
		// Right after the open, the last quote is from before it. Count the
		// age from the open so sources get the same grace as any other time.
		let since = max(quoteTime, MarketHours.sessionStart(containing: now))
		return now.timeIntervalSince(since) > maxAge ? .stale : .live
	}
}
