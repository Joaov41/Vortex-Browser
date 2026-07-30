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
| Cloud | The provided Apple Intelligence Shortcut | [Install RSS Reader Cloud Summary](https://www.icloud.com/shortcuts/ffd100c18df34543a2c8ca25c321f6c6) |
| Apple PCC Gateway | The user's own Mac gateway | TestFlight requires iOS 27 or later |
| MLX | A compatible model downloaded to the device | Configure an MLX model in Vortex |
| ChatGPT / Gemini | The provider's website in Vortex | Sign in to the provider |

### TestFlight on iOS 26 and iOS 27

- **iOS 26:** Apple PCC Gateway is disabled. If it was selected in an earlier build, Vortex switches to **Local**. Local, Cloud, MLX, ChatGPT and Gemini remain available.
- **iOS 27 or later:** Apple PCC Gateway can be selected and configured. Vortex does not include a developer gateway address or token. Each tester must run and secure their own gateway.
- **Cloud is separate from Apple PCC Gateway.** Cloud runs the Shortcut named in Vortex. The user decides which model that Shortcut uses.

See [Using AI models in Vortex](docs/AI_MODELS.md) for the complete Cloud Shortcut and Apple PCC Gateway setup.

## Local gateway script

The optional gateway script binds to the local network and generates a fresh bearer token when it starts:

```sh
./scripts/start-fm-pcc-gateway.command
```

Keep generated tokens and signing credentials out of source control. Do not expose the gateway to the public internet.

## License

MIT License. You may use, modify, and distribute this code as long as the
copyright and license notice crediting Joao Valente are retained. See
[LICENSE](LICENSE).
