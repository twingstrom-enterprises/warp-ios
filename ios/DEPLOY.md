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
- **Manual:** Actions → *iOS TestFlight* → *Run workflow* (optional `marketing_version` input overrides `project.pbxproj`)

## Versioning (TestFlight updates)

Apple uses two version fields. CI must set both explicitly at archive time so TestFlight treats each release as an update testers can install.

| Xcode setting | Info.plist key | Role |
|---------------|----------------|------|
| `MARKETING_VERSION` | `CFBundleShortVersionString` | User-visible version (e.g. `1.4`). **Must increase** when you want testers to see a new app version in TestFlight. |
| `CURRENT_PROJECT_VERSION` | `CFBundleVersion` | Build number (e.g. `3`). **Must increase** for every upload with the same marketing version. |

**When to bump what**

- **Bump `MARKETING_VERSION`** (in `ios/warp-ios/warp-ios.xcodeproj/project.pbxproj` Debug + Release) when shipping a new TestFlight *version* — e.g. testers are on `1.3` and you want them notified about `1.4`. CI reads this from `project.pbxproj` unless you pass a manual `marketing_version` workflow input.
- **Do not hardcode the build number.** CI sets `CURRENT_PROJECT_VERSION` from `github.run_number`, which auto-increments on every workflow run (1, 2, 3, …). Never set it to a fixed value like `1` in the workflow.
- If TestFlight “quietly publishes” without notifying testers, the marketing version likely did not increase above what they already have installed.

The archive step passes `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` to `xcodebuild`, then a **Verify archived app version** step reads them back from the `.xcarchive` and fails the job if they do not match.

### Verify version after upload

1. **CI logs:** open the *Resolve app version* and *Verify archived app version* steps — they print `CFBundleShortVersionString` and `CFBundleVersion`.
2. **TestFlight:** App Store Connect → your app → TestFlight → select the build; version and build number appear in the build details.
3. **Local IPA inspection:**
   ```bash
   unzip -p path/to/warp-ios.ipa Payload/warp-ios.app/Info.plist | plutil -p -
   ```
   Look for `CFBundleShortVersionString` and `CFBundleVersion`.

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
