# Releasing Kiri as a download

A disk image from your own website opens without warnings only when the app and the image are signed with a **Developer ID** and **notarized** by Apple. Without that, macOS says "Apple could not verify Kiri is free of malware" and people have to go through System Settings ▸ Privacy & Security to open it. `scripts/dmg.sh` does all of it in one go; the setup below is once per Mac.

## One-time setup

1. **Apple Developer Program** membership (paid, yearly) for your Apple Account: <https://developer.apple.com/programs/>. Your **team ID** is under Membership details at <https://developer.apple.com/account>.
2. **A Developer ID Application certificate** (not "Apple Distribution", which is for the App Store). The easiest way: Xcode ▸ Settings ▸ Accounts ▸ your team ▸ Manage Certificates… ▸ + ▸ Developer ID Application. It lands in your login keychain with its private key. Back it up (Keychain Access ▸ export as .p12): a lost key means a new certificate.
   Check it's there:
   ```sh
   security find-identity -v -p codesigning
   # 1) ABC123… "Developer ID Application: Your Name (TEAMID1234)"
   ```
3. **Credentials for the notary service**, saved in the keychain as a profile so no password is ever typed into a script or the repo. Either an app-specific password (make one at <https://account.apple.com> ▸ Sign-In and Security ▸ App-Specific Passwords):
   ```sh
   xcrun notarytool store-credentials kiri-notary \
       --apple-id you@example.com --team-id TEAMID1234
   # asks for the app-specific password
   ```
   or an App Store Connect API key (Users and Access ▸ Integrations ▸ Team Keys, role Developer), better for CI:
   ```sh
   xcrun notarytool store-credentials kiri-notary \
       --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   ```

## Making a release

1. Set the version in `App/project.yml` (`MARKETING_VERSION`, and bump `CURRENT_PROJECT_VERSION`).
2. Build, sign, notarize and staple:
   ```sh
   export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID1234)"
   export NOTARY_PROFILE=kiri-notary
   scripts/dmg.sh --build
   ```
   This builds the app (for this Mac's architecture; `ARCH="arm64 x86_64"` makes it universal, which a public download should be), signs it with the hardened runtime and a secure timestamp, notarizes and staples it, packs `build/Kiri-<version>.dmg`, signs, notarizes and staples that too, and finally asks Gatekeeper (`spctl`) to accept both. Each notarization usually takes a few minutes. If Apple refuses one, the script prints Apple's log and stops.
3. Upload `build/Kiri-<version>.dmg`. Publishing a SHA-256 next to it is a nice touch: `shasum -a 256 build/Kiri-*.dmg`.

To check a downloaded copy the way a visitor's Mac will:

```sh
xattr -w com.apple.quarantine "0081;$(printf %x $(date +%s));Safari;" Kiri-0.1.0.dmg
spctl --assess --type open --context context:primary-signature -v Kiri-0.1.0.dmg
# Kiri-0.1.0.dmg: accepted  source=Notarized Developer ID
```

## Without the setup

With no `SIGN_IDENTITY`, `scripts/dmg.sh` makes an ad-hoc signed image: fine for your own Mac or a friend who knows to right-click ▸ Open, not for a public download. Setting a notary profile without an identity stops with a message instead of half-signing.

Other ways to pass the notary credentials, for CI where there is no keychain profile: `NOTARY_KEY` (path to the .p8), `NOTARY_KEY_ID` and `NOTARY_ISSUER`; or `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_APP_PASSWORD`. Keep them in the CI's secrets, never in the repo.

## Later

Kiri has no updater yet: a self-hosted app doesn't update itself. [Sparkle](https://sparkle-project.org) is the usual answer (an appcast on the website plus an EdDSA-signed update), worth adding before the first public release.
