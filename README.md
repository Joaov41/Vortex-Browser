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

Swift package dependencies are pinned in `Browser.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

## Website and policies

- [External TestFlight](https://testflight.apple.com/join/KTsJ3qz4)
- [Vortex Browser website](https://joaov41.github.io/Vortex-Browser/)
- [Privacy Policy](https://joaov41.github.io/Vortex-Browser/privacy/)
- [Terms of Service](https://joaov41.github.io/Vortex-Browser/terms/)

## AI models

Vortex has several independent AI backends. You choose one from **AI panel > Model**.

| Model in Vortex | Where it runs | Extra setup |
| --- | --- | --- |
| Local | Apple Foundation Models on the device | Apple Intelligence must be available and enabled |
| Cloud | Apple Private Cloud Compute directly on iOS 27; the provided Apple Intelligence Shortcut on iOS 26 | On iOS 26, [install RSS Reader Cloud Summary](https://www.icloud.com/shortcuts/ffd100c18df34543a2c8ca25c321f6c6) |
| MLX | A compatible model downloaded to the device | Configure an MLX model in Vortex |
| ChatGPT (OpenAI) / Gemini | The provider's website inside Vortex | Sign in inside Vortex |

### TestFlight on iOS 26 and iOS 27

- **iOS 26:** Cloud runs the Shortcut named in Vortex. The user decides which model that Shortcut uses.
- **iOS 27 or later:** Cloud calls Apple's `PrivateCloudComputeLanguageModel` directly. No Mac gateway, host, port, or bearer token is used.
- A saved selection from the retired Apple PCC Gateway is migrated to **Cloud**.

ChatGPT and Gemini use their normal websites, not an OpenAI or Google API key. Vortex can send your question with selected text or extracted page context, then attempts to bring the provider's response back into the AI panel.

See [Using AI models in Vortex](docs/AI_MODELS.md) for the complete setup and privacy details for every backend.

## License

MIT License. You may use, modify, and distribute this code as long as the
copyright and license notice crediting Joao Valente are retained. See
[LICENSE](LICENSE).
