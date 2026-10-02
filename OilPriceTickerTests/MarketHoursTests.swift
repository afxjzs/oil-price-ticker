//
//  MarketHoursTests.swift
//  OilPriceTickerTests
//
//  WTI futures trade Sunday 6pm to Friday 5pm New York time, with a break from
//  5pm to 6pm each weekday. Outside those hours the price can't move, so an old
//  quote is expected and must show as "closed", not as a failure.
//

import Foundation
import Testing
@testable import OilPriceTickerMacApp

/// A moment in New York time. 2026-10-03 is a Saturday (EDT); 2026-01-14 is a Wednesday (EST).
private func ny(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
	var calendar = Calendar(identifier: .gregorian)
	calendar.timeZone = TimeZone(identifier: "America/New_York")!
	return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

struct MarketHoursTests {

	@Test func closedAllDaySaturday() {
		#expect(!MarketHours.isOpen(ny(2026, 10, 3, 12, 0)))
	}

	@Test func opensSundayAtSixPM() {
		#expect(!MarketHours.isOpen(ny(2026, 10, 4, 17, 59)))
		#expect(MarketHours.isOpen(ny(2026, 10, 4, 18, 0)))
	}

	@Test func weekdayBreakFromFiveToSix() {
		#expect(MarketHours.isOpen(ny(2026, 10, 1, 16, 59)))
		#expect(!MarketHours.isOpen(ny(2026, 10, 1, 17, 30)))
		#expect(MarketHours.isOpen(ny(2026, 10, 1, 18, 0)))
	}

	@Test func closesFridayAtFivePM() {
		#expect(MarketHours.isOpen(ny(2026, 10, 2, 16, 59)))
		#expect(!MarketHours.isOpen(ny(2026, 10, 2, 17, 0)))
		#expect(!MarketHours.isOpen(ny(2026, 10, 2, 18, 30)))
	}

	/// Guards against a hardcoded UTC offset: the break is 5pm local in winter too.
	@Test func breakFollowsNewYorkTimeInWinter() {
		#expect(!MarketHours.isOpen(ny(2026, 1, 14, 17, 30)))
		#expect(MarketHours.isOpen(ny(2026, 1, 14, 16, 30)))
	}
}

struct FreshnessTests {

	@Test func recentQuoteWhileOpenIsLive() {
		let now = ny(2026, 10, 1, 14, 0)
		#expect(Freshness.evaluate(quoteTime: now.addingTimeInterval(-12 * 60), now: now) == .live)
	}

	@Test func oldQuoteWhileOpenIsStale() {
		let now = ny(2026, 10, 1, 14, 0)
		#expect(Freshness.evaluate(quoteTime: now.addingTimeInterval(-45 * 60), now: now) == .stale)
	}

	/// Friday's last price on a Saturday is correct, not stale.
	@Test func oldQuoteWhileClosedIsClosed() {
		#expect(Freshness.evaluate(quoteTime: ny(2026, 10, 2, 16, 59), now: ny(2026, 10, 3, 12, 0)) == .closed)
	}

	/// Right after the Sunday open, sources are still catching up: Friday's quote
	/// isn't a failure yet.
	@Test func justAfterTheOpenAnOldQuoteIsNotStaleYet() {
		#expect(Freshness.evaluate(quoteTime: ny(2026, 10, 2, 16, 59), now: ny(2026, 10, 4, 18, 10)) == .live)
	}

	@Test func wellAfterTheOpenAnOldQuoteIsStale() {
		#expect(Freshness.evaluate(quoteTime: ny(2026, 10, 2, 16, 59), now: ny(2026, 10, 4, 18, 40)) == .stale)
	}

	/// Same grace after the weekday 5–6pm break.
	@Test func justAfterTheDailyBreakAnOldQuoteIsNotStaleYet() {
		#expect(Freshness.evaluate(quoteTime: ny(2026, 10, 1, 16, 59), now: ny(2026, 10, 1, 18, 10)) == .live)
	}

	/// A quote stamped slightly ahead of this Mac's clock is fine, not an error.
	@Test func quoteFromTheFutureIsLive() {
		let now = ny(2026, 10, 1, 14, 0)
		#expect(Freshness.evaluate(quoteTime: now.addingTimeInterval(120), now: now) == .live)
	}
}
