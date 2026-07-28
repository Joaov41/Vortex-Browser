# Vortex Browser

Vortex Browser is a SwiftUI browser for iPhone and iPad with tab management, reader tools, content blocking, a share extension, and AI-assisted page summaries.

## Requirements

- Xcode 27
- iOS 26 or later
- An Apple development team for device builds

## Project

Open `Browser.xcodeproj` and run the `Browser` scheme.

The project includes:

- `Browser/` — main iOS app
- `BrowserShare/` — share extension
- `scripts/start-fm-pcc-gateway.command` — optional local Apple Foundation Models gateway

Swift package dependencies are pinned in `Browser.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

## Local gateway

The optional gateway binds to the local network and generates a fresh bearer token when it starts:

```sh
./scripts/start-fm-pcc-gateway.command
```

Keep generated tokens and signing credentials out of source control.
