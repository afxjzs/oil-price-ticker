# OilPriceTicker

🛢️ Lightweight macOS menu-bar app that shows the latest WTI crude price.

## Features

* Scrapes delayed front-month futures price (CLN25) from [Barchart.com](https://www.barchart.com/futures/quotes/CLN25).
* Refresh interval configurable (30–600 s) via Preferences.
* Right-click menu with:
  * Preferences…
  * About (credits & licence)
  * Quit
* Inline barrel emoji ticker (e.g. `🛢️ $79.32`).
* Written in Swift 5.9 / SwiftUI, no private APIs.

## Build & Run

```bash
# macOS 13+ with Xcode 15+ / Swift 5.9
git clone https://github.com/yourname/oil-price-ticker.git
cd oil-price-ticker
swift run OilPriceTicker       # or open Package.swift in Xcode
```

The first build resolves the SwiftPM dependency [SwiftSoup](https://github.com/scinfu/SwiftSoup) for HTML parsing.

## Usage

1. Launch the app – a barrel emoji appears in the menu bar.
2. Left-click to force a refresh.
3. Right-click for Preferences, About or Quit.
4. In Preferences adjust the refresh cadence; value is saved to *UserDefaults*.

## License

Released under the MIT License – see *LICENSE* for details.

## Credits

* Developed by **Douglas E. Rogers** – <https://doug.is>
* HTML parsing via [SwiftSoup](https://github.com/scinfu/SwiftSoup) (MIT). 