# Developer ID Signing and Notarization

LocateApp can be distributed from GitHub Releases as a Developer ID-signed and
notarized Mac app when Apple credentials are configured in GitHub Actions.

Apple references:

- [Developer ID support](https://developer.apple.com/support/developer-id/)
- [Developer ID certificate glossary](https://developer.apple.com/help/glossary/developer-id-certificate/)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)
- [Creating API keys for the App Store Connect API](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)

## Required Apple Account Steps

These steps require the Apple Developer account owner or an admin with the
right privileges. Do not paste private keys or passwords into issues, PRs,
Notion, Slack, or logs.

1. Create a Developer ID Application certificate for the Apple Developer team.
2. Install the certificate in Keychain Access on a trusted Mac.
3. Export the certificate with its private key as a password-protected `.p12`.
4. Create an App Store Connect Team API key for notarization. Individual API
   keys do not work with `notarytool`.
5. Download the `.p8` key once and store it securely.
6. Add the GitHub Actions secrets below.

Developer ID Application is enough for the current DMG/ZIP distribution.
Developer ID Installer is only needed if LocateApp later ships as a signed
`.pkg` installer.

## GitHub Actions Secrets

| Secret | Value |
|---|---|
| `APPLE_DEVELOPER_ID_CERTIFICATE_P12_BASE64` | Base64-encoded `.p12` containing the Developer ID Application certificate and private key |
| `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password for the `.p12` file |
| `APPLE_SIGNING_IDENTITY` | Codesigning identity, for example `Developer ID Application: Example, Inc. (TEAMID)` |
| `APPLE_KEYCHAIN_PASSWORD` | Temporary CI keychain password |
| `APPLE_NOTARY_KEY_P8_BASE64` | Base64-encoded App Store Connect Team API `.p8` private key |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API key ID |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect issuer ID |

Use this command locally to base64-encode files without printing secret values
to shell history:

```bash
python3 - <<'PY'
import base64
from pathlib import Path

for path in ["DeveloperID.p12", "AuthKey_KEYID.p8"]:
    output = Path(path).with_suffix(Path(path).suffix + ".base64")
    output.write_text(base64.b64encode(Path(path).read_bytes()).decode() + "\n")
    print(output)
PY
```

## Release Behavior

When these secrets are present, `.github/workflows/release.yml` imports the
certificate into a temporary keychain, builds the app with Developer ID signing,
submits the app archive and DMG with `xcrun notarytool`, staples tickets to the
app and DMG, then verifies with `codesign`, `spctl`, and `stapler`.

When the secrets are absent, the workflow keeps producing ad-hoc signed ZIP and
DMG artifacts. That fallback keeps local and CI release checks usable while the
Apple account setup is pending.
