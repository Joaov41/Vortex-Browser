# Setting Up Default Browser Support

This guide explains how to make your browser app appear as a "Default Browser" option in iOS Settings.

## Step 1: Update Info.plist

Add or modify the `CFBundleURLTypes` key in `Browser/Info.plist`:

```xml
<key>CFBundleURLTypes</key>
<array>
    <!-- Existing custom scheme -->
    <dict>
        <key>CFBundleTypeRole</key>
        <string>Editor</string>
        <key>CFBundleURLName</key>
        <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>webmebrowser</string>
        </array>
    </dict>
    <!-- NEW: HTTP/HTTPS for Default Browser support -->
    <dict>
        <key>CFBundleTypeRole</key>
        <string>Viewer</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>http</string>
            <string>https</string>
        </array>
    </dict>
</array>
```

## Step 2: Handle Incoming URLs

Ensure your app handles incoming URLs. In your SwiftUI App struct (e.g., `BrowserApp.swift`), add:

```swift
@main
struct BrowserApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    // Handle the incoming URL
                    // Open it in a new tab or the current tab
                    NotificationCenter.default.post(
                        name: .openURLFromExternal,
                        object: url
                    )
                }
        }
    }
}

// Define the notification name somewhere accessible
extension Notification.Name {
    static let openURLFromExternal = Notification.Name("openURLFromExternal")
}
```

Then in your `ContentView` or `BrowserViewModel`, listen for this notification and open the URL.

## Step 3: Test

1. Build and run the app on your device
2. Go to **Settings → Apps → Default Apps → Browser** (iOS 18+)
   - Or **Settings → [Your App Name] → Default Browser App** (iOS 14-17)
3. Your app should appear in the list
4. Select it as the default browser
5. Test by tapping a link in Mail, Notes, or Messages - it should open in your app

## Notes

- This feature requires iOS 14.0 or later
- Apple reviews browser apps carefully - ensure URL handling works correctly before App Store submission
- In the EU (due to DMA), users may see a browser choice screen on first iOS setup
