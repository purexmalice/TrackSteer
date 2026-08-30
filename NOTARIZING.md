# Notarizing TrackSteer

Three one-time steps, then `./notarize.sh` is the whole release process.

Worth doing for two reasons. Users stop seeing *"the developer cannot be
verified"*, and — the bigger one — **Accessibility permission survives
updates**. Ad-hoc signatures change with every build, so macOS revokes the grant
each time and the app silently stops working. A stable Developer ID identity
ends that.

All three steps need your Apple credentials and an unlocked keychain, so they
are yours to do. Nothing here should be automated by anything but you.

## 1. Get a Developer ID Application certificate

In Xcode: **Settings → Accounts → (your Apple ID) → Manage Certificates → `+` →
Developer ID Application**.

Requires a paid Apple Developer Program membership. Verify with:

```bash
security find-identity -v -p codesigning
```

You want a line reading `Developer ID Application: ...`.

## 2. Create an app-specific password

At [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security →
App-Specific Passwords. This is not your Apple ID password; it is a separate
credential you can revoke.

## 3. Store it for notarytool

```bash
xcrun notarytool store-credentials tracksteer \
  --apple-id "you@example.com" \
  --team-id "YOURTEAMID" \
  --password "the-app-specific-password"
```

Your team ID is on the [membership page](https://developer.apple.com/account).
This saves the credential into your keychain, so it is entered once and never
appears in a script or in git.

## Then, for every release

```bash
./notarize.sh
```

Signs with hardened runtime, submits to Apple, waits, staples the ticket into
the app, and produces `TrackSteer-notarized.zip` ready to upload.

The app needs no entitlements beyond the hardened runtime — Accessibility is
granted by the user at runtime, not declared in the bundle.
