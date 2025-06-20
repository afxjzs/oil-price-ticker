// swift-tools-version:5.9
// Package.swift
import PackageDescription

let package = Package(
	name: "OilPriceTicker",
	platforms: [
		.macOS(.v13)
	],
	products: [
		.executable(name: "OilPriceTicker", targets: ["OilPriceTicker"])
	],
	dependencies: [
		.package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0")
	],
	targets: [
		.executableTarget(
			name: "OilPriceTicker",
			dependencies: [
				.product(name: "SwiftSoup", package: "SwiftSoup")
			]
		),
		.testTarget(
			name: "OilPriceTickerTests",
			dependencies: ["OilPriceTicker"]
		)
	]
) 