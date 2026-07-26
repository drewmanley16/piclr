# Release (TestFlight)

## Upload

```sh
ASC_KEY_ID=<key> ASC_ISSUER_ID=<issuer> scripts/testflight.sh
```

The script archives (Release), exports with manual signing via
`ExportOptions.plist`, and uploads with `altool`. Prereqs are documented in the
script header (App Store Connect API key saved to
`~/.appstoreconnect/private_keys/`).

## Before every upload

1. **Bump `CURRENT_PROJECT_VERSION` in `project.yml`** — App Store Connect
   rejects repeated build numbers within a marketing version.
2. `xcodegen generate` so the bump lands in the project.

## Signing & identifiers

- Team: `X9H68STU8F`. Three provisioned bundle ids: `com.pickleball.ai` (app),
  `com.pickleball.ai.widget` (widget extension), `com.pickleball.ai.watchapp`
  (watch app) — the widget and watch targets carry their own provisioning
  profiles for TestFlight.
- Marketing version and build number both live in `project.yml`
  (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`).
- Specific key ids / credentials are not stored in this repo.

## Guards in the script

- **Monetization guard**: once `FeatureFlags.monetizationEnabled` loses its
  `#if DEBUG` gate (launch flip), the script refuses to archive without
  `PickleballAI/RevenueCat.plist` — otherwise the shipped paywall's purchases
  would all fail.

## StoreKit testing

- Simulator: the run scheme injects `PickleballAI.storekit`, so purchases hit
  the local StoreKit test store (Xcode → Debug → StoreKit → Manage
  Transactions).
- Apple sandbox on device: set the scheme's StoreKit Configuration to None.

## CI

`.github/workflows/lint.yml` runs the SwiftLint tripwires (`--strict`) on every
PR. There is no CI build or automated release pipeline; TestFlight uploads are
run locally via the script above.
