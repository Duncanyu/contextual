## Development notes (macOS permissions)

macOS privacy permissions (Accessibility, Screen Recording) **cannot be granted or reset programmatically** by this app. During development, permissions may appear to “break” after rebuilds if the app’s identity changes (bundle id, signing, or the built app location).

### Recommendations

- Keep the **Debug bundle identifier** stable (`com.contextual.Contextual`).
- Keep signing settings stable (Team / signing identity) when possible.
- Prefer running the same built app location consistently (Xcode “Run”).

### If permissions break after a clean build

1. Open **System Settings → Privacy & Security**.
2. Remove / disable **Contextual** from:
   - **Accessibility**
   - **Screen Recording**
3. Re-run the app from Xcode and re-enable the toggles once.

### In-app shortcuts

The assistant panel includes buttons to open:
- Accessibility settings
- Screen Recording settings

