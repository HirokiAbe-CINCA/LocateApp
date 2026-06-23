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
| `SPARKLE_PUBLIC_ED_KEY` | Public EdDSA key printed by Sparkle `generate_keys`; embedded in release app `Info.plist` |
| `SPARKLE_ED_PRIVATE_KEY` | Private EdDSA key exported by Sparkle `generate_keys -x`; used only by CI to sign update archives and appcasts |

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

Generate Sparkle keys from a trusted Mac with the Sparkle distribution tools:

```bash
./bin/generate_keys
./bin/generate_keys -x sparkle-ed25519-private-key.txt
```

Store the printed public key as `SPARKLE_PUBLIC_ED_KEY`. Store the exact
contents of `sparkle-ed25519-private-key.txt` as `SPARKLE_ED_PRIVATE_KEY`.
Never commit the private key or paste it into issues, PRs, chat, or logs.
CI derives the public key from `SPARKLE_ED_PRIVATE_KEY` and fails the release
if it does not match the public key embedded in the app.

## Release Behavior

When these secrets are present, `.github/workflows/release.yml` imports the
certificate into a temporary keychain, builds the app with Developer ID signing,
submits the app archive and DMG with `xcrun notarytool`, staples tickets to the
app and DMG, signs a Sparkle appcast for the ZIP update, then verifies with
`codesign`, `spctl`, `stapler`, and appcast structure checks.

The Sparkle feed URL embedded in signed builds is:

```text
https://hirokiabe-cinca.github.io/LocateApp/appcast.xml
```

The release workflow uploads `appcast.xml` to the GitHub Release for audit and
deploys the same file to GitHub Pages after the Release assets are available.

Tag releases require the Apple signing/notarization secrets and Sparkle secrets.
They fail if notarization or appcast generation cannot complete. Local manual
packaging can still be run without those secrets, but those artifacts are not
suitable for the automatic-update release channel.
