# Releasing Holo

Holo is distributed directly from GitHub Releases as a signed and notarized DMG. It is not built for the Mac App Store.

## One-time Apple setup

1. Join the Apple Developer Program and create a **Developer ID Application** certificate for the team. Do not use a Mac App Distribution certificate.
2. Install the certificate and its private key in Keychain Access. Export both together as a password-protected `.p12` file for CI, and store that file securely outside this repository.
3. Create App Store Connect API-key credentials that can submit software for notarization. Download the `.p8` key when it is offered; Apple only provides that download once. Record its key ID and issuer ID.
4. Install the local tools:

   ```sh
   brew install xcodegen
   xcode-select --install
   ```

For local notarization, either use the API key directly or save Apple ID credentials in the login keychain:

```sh
xcrun notarytool store-credentials "holo-notary" \
  --apple-id "APPLE_ID_EMAIL" \
  --team-id "APPLE_TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

The password in that command must be an app-specific Apple ID password, not the normal account password.

## GitHub repository setup

In **Settings → Secrets and variables → Actions**, add these repository secrets:

| Secret | Value |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Base64 text of the exported Developer ID `.p12` |
| `P12_PASSWORD` | Password used when exporting the `.p12` |
| `APP_STORE_CONNECT_API_KEY_BASE64` | Base64 text of the App Store Connect `.p8` key |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect API issuer ID |

On macOS, copy a file's base64 text without printing it to the terminal:

```sh
base64 -i DeveloperIDApplication.p12 | pbcopy
base64 -i AuthKey_KEY_ID.p8 | pbcopy
```

In **Settings → Actions → General**, ensure repository policy allows workflows to use read/write permissions. The release workflow requests `contents: write` so it can create a GitHub Release and upload its DMG. No signing identity or team-ID secret is needed; CI derives both from the imported certificate.

## Local release

Find the exact signing identity with `security find-identity -v -p codesigning`, then choose one notarization method.

Using a stored keychain profile:

```sh
export DEVELOPER_ID_APPLICATION='Developer ID Application: ORGANIZATION (TEAM_ID)'
export DEVELOPMENT_TEAM='TEAM_ID'
export NOTARYTOOL_KEYCHAIN_PROFILE='holo-notary'
scripts/release.sh
```

Using an App Store Connect API key:

```sh
export DEVELOPER_ID_APPLICATION='Developer ID Application: ORGANIZATION (TEAM_ID)'
export DEVELOPMENT_TEAM='TEAM_ID'
export APP_STORE_CONNECT_API_KEY_PATH='/secure/path/AuthKey_KEY_ID.p8'
export APP_STORE_CONNECT_KEY_ID='KEY_ID'
export APP_STORE_CONNECT_ISSUER_ID='ISSUER_ID'
scripts/release.sh
```

The default artifact is `dist/Holo.dmg`. Set `DMG_PATH` to another `.dmg` path inside the repository when a versioned filename is useful:

```sh
DMG_PATH="$PWD/dist/Holo-v0.1.0.dmg" scripts/release.sh
```

The script regenerates the project, makes an unsigned Release archive, signs embedded code and `Holo.app` with timestamped Developer ID signatures and hardened runtime, creates the DMG, waits for notarization, then staples and validates the DMG ticket. Signing and notarization require network access and real Apple credentials.

## CI release runbook

1. Update `MARKETING_VERSION` and, when appropriate, `CURRENT_PROJECT_VERSION` in `project.yml`.
2. Run the normal tests and merge the version change to the release commit.
3. Create an annotated tag beginning with `v`, such as `v0.1.0`, on that commit.
4. Push the tag to GitHub. `.github/workflows/release.yml` runs on `v*`, builds on `macos-26`, notarizes `Holo-<tag>.dmg`, creates the matching GitHub Release, and uploads the DMG.
5. Confirm the workflow succeeds, download the published DMG, and verify that it opens and launches on a separate Mac before announcing the release.

If the workflow fails before compilation, check that all five secrets are present and that the `.p12` contains both the Developer ID certificate and its private key. If notarization fails, inspect the `notarytool` status output for signing, entitlement, or API-key authorization errors.
