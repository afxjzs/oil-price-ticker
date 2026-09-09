//
//  RefreshIntervalTests.swift
//  OilPriceTickerTests
//

import Foundation
import Testing
@testable import OilPriceTickerMacApp

struct RefreshIntervalTests {

	@Test func defaultIsFifteenMinutes() {
		#expect(RefreshInterval.default == 900)
	}

	/// The default has to be settable in Preferences, or the app ships in a
	/// state its own UI cannot express.
	@Test func defaultSitsInsideTheAllowedRange() {
		#expect(RefreshInterval.default >= RefreshInterval.minimum)
		#expect(RefreshInterval.default <= RefreshInterval.maximum)
	}

	/// If the default were not a preset, a fresh install would open Preferences
	/// showing a redundant "custom" row alongside the identical preset.
	@Test func defaultIsOneOfTheOfferedPresets() {
		#expect(RefreshInterval.presets.contains(RefreshInterval.default))
	}

	@Test func presetsStayInsideTheAllowedRange() {
		for preset in RefreshInterval.presets {
			#expect(preset >= RefreshInterval.minimum)
			#expect(preset <= RefreshInterval.maximum)
		}
	}

	@Test func labelsWholeMinutesWithoutSeconds() {
		#expect(RefreshInterval.label(for: 900) == "15 min")
		#expect(RefreshInterval.label(for: 60) == "1 min")
	}

	@Test func labelsSubMinuteValuesInSeconds() {
		#expect(RefreshInterval.label(for: 30) == "30 sec")
	}

	@Test func labelsMixedValues() {
		#expect(RefreshInterval.label(for: 90) == "1 min 30 sec")
	}
}
