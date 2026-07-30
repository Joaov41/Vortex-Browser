# Using AI models in Vortex

Open the AI panel with the sparkles button, then choose a backend from **Model**.

## TestFlight behavior

### iOS 26

The separate **Apple PCC Gateway** option is disabled in TestFlight on iOS 26. Its host, port, model, token and connection test controls are also disabled.

If Apple PCC Gateway was saved as the selected backend in an earlier build, Vortex changes the selection to **Local**. This does not send a request to the gateway.

The other backends remain available:

- **Local:** Apple's model on the device.
- **Cloud:** a Shortcut owned and configured by the user.
- **MLX:** a compatible model downloaded to the device.
- **ChatGPT / Gemini:** the provider's web interface.

### iOS 27 or later

Apple PCC Gateway is enabled. Vortex does not provide a shared gateway, Mac address or bearer token. Each user must run their own gateway and enter their own settings.

## Local

Local uses Apple Foundation Models on the iPhone or iPad. It does not use the Mac gateway.

Apple Intelligence must be supported by the device, enabled in Settings, and available for the current language and region. If it is unavailable, Vortex shows the model error instead of silently sending the request elsewhere.

## Cloud with Shortcuts

Cloud does not refer to a server operated by Vortex. It launches a Shortcut installed on the user's device, passes the question and selected page context to it as text, then waits for the Shortcut to copy its response to the clipboard.

### Create the Shortcut

1. Open Apple's **Shortcuts** app and create a new shortcut.
2. Name it `RSS Reader Cloud Summary`, or choose another name and enter that exact name in Vortex's **Shortcut name** field.
3. Add the **Use Model** action.
4. Set the action's input to **Shortcut Input**.
5. Choose the model that should answer:
   - **On-Device** for Apple's model on the device.
   - **Private Cloud Compute** for Apple's PCC model.
   - **Extension Model** for a supported extension such as ChatGPT.
6. Leave **Follow Up** disabled so the Shortcut can finish without waiting for another interactive response.
7. Add **Copy to Clipboard** after **Use Model** and set it to copy the model's response.
8. Run the Shortcut once in Shortcuts and approve any requested Apple Intelligence, model or clipboard permissions.

Apple documents the available model choices in [Use Apple Intelligence in Shortcuts on iPhone](https://support.apple.com/guide/iphone/iph78c41eaf8/ios).

### Use it in Vortex

1. Open Vortex's AI panel.
2. Choose **Cloud** from **Model**.
3. Enter the Shortcut's exact name in **Shortcut name**.
4. Ask a question or request a summary.
5. Shortcuts opens and runs the configured model. Return to Vortex if iOS does not return automatically.

Vortex waits for a new clipboard value for up to two minutes. If the Shortcut does not copy its response, Vortex cannot receive the answer.

The Cloud backend remains available on iOS 26. A Shortcut may offer On-Device, Private Cloud Compute or an Extension Model depending on the device, OS version, Apple Intelligence settings, language, region and the services configured by the user.

## Apple PCC Gateway

Apple PCC Gateway is different from the Cloud Shortcut backend. It connects Vortex over the local network to a gateway running on the user's Mac. The gateway then requests the `pcc` model through the Foundation Models command-line tool.

### Mac setup

1. Clone this repository on the Mac.
2. Confirm that the `fm` command is installed and configured.
3. Confirm that `fm available --model pcc` reports the model as available.
4. From the repository root, run:

   ```sh
   ./scripts/start-fm-pcc-gateway.command
   ```

5. Keep the terminal window open. The script prints:
   - The Mac's local IP address.
   - The gateway port, normally `1977`.
   - A newly generated bearer token.
   - The model name, normally `pcc`.

### Vortex setup on iOS 27 or later

1. Connect the iPhone or iPad and the Mac to the same trusted local network.
2. In Vortex settings, find **Apple PCC Gateway**.
3. Enter the Mac's local IP address in **Mac host/IP**.
4. Keep port `1977` unless the script was started with a different port.
5. Enter `pcc` as the model unless the gateway uses another model.
6. Paste the token printed by the script into **Gateway token**.
7. Tap **Test PCC Gateway**.
8. After the test reports that the model is available, open the AI panel and choose **Apple PCC Gateway**.

The token is stored in the user's Apple Keychain. The default host is `127.0.0.1` and the default token is empty, so an external tester cannot connect until they enter their own Mac address and token.

### Gateway security

- Run the gateway only on a trusted network.
- Do not forward its port or expose it to the public internet.
- Do not publish or commit the generated bearer token.
- Stop the script when the gateway is not needed.
- The local device-to-Mac connection uses HTTP with bearer-token authentication. Anyone who can reach the gateway and obtain the token could submit requests.

## Privacy summary

- Local and MLX process requests on the device.
- Cloud sends the prompt and page context to the Shortcut and whatever model the user selected inside it.
- Apple PCC Gateway sends the prompt and page context to the user's Mac gateway.
- ChatGPT and Gemini send content through the selected provider's web interface.

Review the [Privacy Policy](https://joaov41.github.io/Vortex-Browser/privacy/) before using a backend with sensitive page content.
