# Using AI models in Vortex

Open the AI panel with the sparkles button, then choose a backend from **Model**.

## Apple Cloud on iOS 26 and iOS 27

Vortex keeps one **Cloud** choice in the interface, but uses the Apple-supported route available on each OS version.

### iOS 27 or later

Cloud calls Apple's `PrivateCloudComputeLanguageModel` directly. The request does not go through a user-run Mac gateway, and there are no host, port, model-name, or bearer-token settings.

The device, Apple Intelligence settings, language, region, signing profile, and Apple's service availability determine whether Private Cloud Compute can answer. Vortex shows the returned error rather than silently switching to another provider.

### iOS 26

Cloud runs a Shortcut owned and configured by the user. Vortex passes the question and selected page context as text. The Shortcut's textual output returns to Vortex through a request-specific `x-callback-url`.

The callback contains a random request identifier, so an unrelated clipboard change cannot be mistaken for the answer. For compatibility with older copies of the supplied Shortcut, Vortex reads the clipboard only after the matching Shortcut success callback and only when no textual result was returned.

#### Install the supplied Shortcut

1. Open [RSS Reader Cloud Summary on iCloud](https://www.icloud.com/shortcuts/ffd100c18df34543a2c8ca25c321f6c6) on the iPhone or iPad.
2. Tap **Get Shortcut**, then add it to Apple Shortcuts.
3. Keep its name as `RSS Reader Cloud Summary`, which is Vortex's default.
4. Run it once in Shortcuts and approve any requested Apple Intelligence permission.

The supplied Shortcut accepts Vortex's text as **Shortcut Input**, runs Apple's **Use Model** action, and returns the result. Users can inspect it before adding it or change the model Apple exposes to the Shortcut.

To use a renamed or custom Shortcut, enter its exact name in Vortex. It must accept text input and return text output. A Shortcut may offer On-Device, Private Cloud Compute, or an Extension Model depending on the device and configuration.

If the retired **Apple PCC Gateway** backend was saved by an older Vortex build, the selection is migrated to **Cloud** and its obsolete host/token configuration is erased.

## Local

Local uses Apple Foundation Models on the iPhone or iPad. It does not use Private Cloud Compute or a Mac gateway.

Apple Intelligence must be supported by the device, enabled in Settings, and available for the current language and region. If it is unavailable, Vortex shows the model error instead of silently sending the request elsewhere.

## MLX

MLX runs a compatible downloaded model on the device. Configure the model identifier and token limits from the AI settings. Model downloads and inference can use significant storage, memory, and battery.

## ChatGPT and Gemini

These choices use the providers' websites inside Vortex. They do not require an OpenAI or Google API key.

### Sign in

1. Open Vortex settings.
2. Tap **Log In to ChatGPT** or **Log In to Gemini**.
3. Sign in on the provider's own page.
4. Open the AI panel and choose **ChatGPT** or **Gemini**.

Vortex keeps that website session in its in-app browser data store. It is separate from a Safari login. **Reset ChatGPT** or **Reset Gemini** clears the matching provider's Vortex website data.

### Ask about a page

When the user submits a question with ChatGPT or Gemini selected, Vortex combines the question with selected text or extracted page context, opens the exact approved provider origin, inserts the prompt, and attempts to capture the completed response back into the AI panel.

Automatic insertion and capture depend on the provider's current website. A website update, login prompt, or consent screen can interrupt the flow. Provider privacy, retention, account, and safety rules apply.

## Privacy summary

- Local and MLX process requests on the device.
- Cloud on iOS 27 uses Apple's direct Private Cloud Compute API.
- Cloud on iOS 26 sends content to the user's Shortcut and the model selected inside it.
- ChatGPT and Gemini send content through the selected provider's exact website origin.

Review the [Privacy Policy](https://joaov41.github.io/Vortex-Browser/privacy/) before using a backend with sensitive page content.
