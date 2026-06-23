# iOS TestFlight Deployment

GitHub Actions deploys the Warp iOS app to TestFlight when iOS-related changes merge to `main`.

Workflow: [`.github/workflows/ios-testflight.yml`](../.github/workflows/ios-testflight.yml)

## Triggers

- **Automatic:** push to `main` when any of these change:
  - `ios/**`
  - `crates/warp_ios_bridge/**`
  - `scripts/build_ios_xcframework.sh`
  - `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml`
  - the workflow file itself
- **Manual:** Actions → *iOS TestFlight* → *Run workflow*

Build numbers use `github.run_number` so each upload gets a unique `CFBundleVersion`.

## One-time App Store Connect setup

1. Create the app in [App Store Connect](https://appstoreconnect.apple.com/) with bundle ID `twingstrom-enterprises.warp-ios.dev`.
2. Under **Users and Access → Integrations → App Store Connect API**, create an API key with **App Manager** (or **Admin**) role.
3. Download the `.p8` key once and note the **Key ID** and **Issuer ID**.
4. In [Apple Developer → Certificates](https://developer.apple.com/account/resources/certificates/list), ensure an **Apple Distribution** certificate exists for team `88GH3J5VCZ`.
5. Export that certificate as a `.p12` (with a password) for CI import.

## GitHub repository secrets

Configure under **Settings → Secrets and variables → Actions → Repository secrets**:

| Secret | Description |
|--------|-------------|
| `APP_STORE_CONNECT_API_KEY_ID` | App Store Connect API Key ID |
| `APP_STORE_CONNECT_API_ISSUER_ID` | App Store Connect Issuer ID |
| `APP_STORE_CONNECT_API_KEY` | Full `.p8` PEM contents **or** base64-encoded `.p8` |
| `APPLE_CERTIFICATE_BASE64` | Base64-encoded Apple Distribution `.p12` (`base64 -i cert.p12 \| pbcopy`) |
| `APPLE_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |

No secrets are committed to the repo.

## What the workflow does

1. Installs Rust 1.92.0 with iOS targets
2. Runs `scripts/build_ios_xcframework.sh` (Rust bridge + UniFFI Swift bindings)
3. Writes the App Store Connect API `.p8` key to a temp file for `xcodebuild` authentication
4. Imports the Apple Distribution certificate (`.p12`) into the ephemeral keychain
5. Downloads an App Store provisioning profile for `twingstrom-enterprises.warp-ios.dev`
6. Archives with `xcodebuild` using manual signing (`Apple Distribution` + downloaded profile) and ASC API auth flags (`-authenticationKeyID`, `-authenticationKeyIssuerID`, `-authenticationKeyPath`, `-allowProvisioningUpdates`) so no Xcode Accounts login is required
7. Exports an IPA with the same ASC API auth flags
8. Uploads to TestFlight via `apple-actions/upload-testflight-build`

## Local verification

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
cargo check --target aarch64-apple-ios -p warp_ios_bridge
bash scripts/build_ios_xcframework.sh
```

Archive locally in Xcode (**Product → Archive**) to validate signing outside CI.

## Xcode Cloud parity

`ci_scripts/ci_post_clone.sh` mirrors the Rust bridge build step for optional Xcode Cloud use. GitHub Actions is the primary deployment path.

## Limitations

- **Distribution certificate required:** App Store Connect API keys can download provisioning profiles but cannot replace a distribution certificate. You must provide the `.p12` secrets above.
- **First upload:** App Store Connect must already have the app record for bundle ID `twingstrom-enterprises.warp-ios.dev`.
- **Processing time:** TestFlight builds may take several minutes to process after upload; the workflow does not wait for Apple processing to finish.
- **Path filters:** Changes outside the listed paths (e.g. only desktop Rust crates) do not trigger a deploy even if they indirectly affect the bridge.
