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

## Making a release on your Mac

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

## Releasing from GitHub

`.github/workflows/release.yml` does a release by itself when a version tag is pushed:

```sh
git tag -a v0.2.0 -m "Kiri 0.2.0

- What's new, in Markdown: this becomes the release notes and the text of the update window."
git push origin v0.2.0
```

On a macOS runner it builds a universal app with the tag's version (`0.2.0`) and the number of commits as its build number, signs it with your Developer ID from a keychain that exists only for that job, notarizes and staples the app and the disk image with an App Store Connect API key, signs the image for Sparkle, writes the update feed, and publishes `Kiri-0.2.0.dmg`, its SHA-256 and `appcast.xml` as release `v0.2.0` of this repo, with the workflow's own `GITHUB_TOKEN`. The repo must be **public**: Sparkle downloads updates without signing in, and a private repo's release files answer with a 404. No version needs changing in `App/project.yml` first: the tag decides.

The job stops early, before the long build, if a secret is missing, the update key isn't in `App/project.yml`, the repo isn't public, or that release already exists. It also checks the update's signature against the key built into the app, so a mismatched key pair fails the release instead of every update.

### One-time setup

`scripts/release-setup.sh`, run on your Mac in the repo, does all of it and asks before each step (it needs the GitHub CLI: `brew install gh && gh auth login`). By hand, these are the parts:

1. **Make the repo public**: Settings ▸ General ▸ Danger Zone ▸ Change visibility (or `gh repo edit ErikHellman/kiri --visibility public --accept-visibility-change-consequences`). The code and its whole history become visible, so nothing secret may ever have been committed.
2. **The update signing key.** Sparkle checks every update against an EdDSA key. With [Sparkle 2.10.1's tools](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1) (`bin/` in `Sparkle-2.10.1.tar.xz`):
   ```sh
   ./bin/generate_keys            # makes the key, keeps it in your login keychain
   ./bin/generate_keys -p         # prints the public key
   ./bin/generate_keys -x sparkle-private-key   # exports the private key, for the secret
   ```
   The public key goes into `App/project.yml` as `KIRI_SPARKLE_PUBLIC_KEY` (it is public; commit it). The private key becomes the `SPARKLE_PRIVATE_KEY` secret; delete the exported file afterwards. **Don't lose the key in the keychain**: copies of Kiri already out there accept only updates signed with it.
3. **The Developer ID as a .p12.** Keychain Access ▸ login ▸ My Certificates ▸ "Developer ID Application: Hellman Software AB (72AFW5CP97)" ▸ right-click ▸ Export… ▸ .p12, with a password.
4. **An App Store Connect API key** for notarization: [App Store Connect ▸ Users and Access ▸ Integrations ▸ App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api) ▸ Team Keys ▸ +, access **Developer**. Download `AuthKey_XXXXXXXXXX.p8` (only possible once). Note the key ID and the issuer ID shown above the list.

Then add these as [repository secrets of kiri](https://github.com/ErikHellman/kiri/settings/secrets/actions) (Settings ▸ Secrets and variables ▸ Actions):

| Secret | What | From |
| --- | --- | --- |
| `DEVELOPER_ID_P12` | the .p12, base64 | `base64 -i DeveloperID.p12 \| pbcopy` |
| `DEVELOPER_ID_P12_PASSWORD` | its export password | step 3 |
| `NOTARY_KEY_P8` | the .p8 file's text, `-----BEGIN PRIVATE KEY-----` and all | `pbcopy < AuthKey_XXXXXXXXXX.p8` |
| `NOTARY_KEY_ID` | the API key's ID, like `XXXXXXXXXX` | step 4 |
| `NOTARY_ISSUER_ID` | the issuer ID, a UUID | step 4 |
| `SPARKLE_PRIVATE_KEY` | the exported EdDSA private key | `pbcopy < sparkle-private-key` |
| `VAKA_TOKEN` (optional) | a Vaka API token with write access to the `kiri-macos` project, for the dSYM upload | the Vaka admin UI, https://vaka.fly.dev/ui |

`KIRI_FEED_URL` in `App/project.yml` must point at this repo's releases; the job refuses to run when it doesn't (a fork, say).

When the Developer ID certificate is renewed, export and store the new .p12.

## Updates

Kiri updates itself with [Sparkle](https://sparkle-project.org) 2 (`App/Kiri/Updater.swift`):

- Kiri ▸ **Check for Updates…** looks at once and says when Kiri is up to date.
- Once a day, in the background, Kiri looks by itself; a new version is downloaded, checked against `SUPublicEDKey`, and installed when Kiri quits. Settings ▸ Updates turns the daily check off and shows which version this is.
- The feed is `https://github.com/ErikHellman/kiri/releases/latest/download/appcast.xml` (`KIRI_FEED_URL`), which always answers with the newest release's `appcast.xml`. It holds just that one version (`scripts/appcast.py`); Sparkle compares build numbers (`CFBundleVersion`), so a newer release always has the larger one. The build number is the number of commits, so tag a commit after the last release's: a second tag on the same commit gets the same build number, and copies with the earlier version never see it as an update.
- A build without a public key or a feed, such as one from a checkout before the key was added, doesn't update itself: Check for Updates… is disabled, and Settings says so. Debug self-tests never start Sparkle.

Sparkle's helpers inside `Kiri.app` (its installer and the `Autoupdate` tool) are signed one by one, inside out, by `scripts/codesign-app.sh`, which `scripts/build.sh` and `scripts/dmg.sh` both use: `codesign --deep` would do it in no particular order, which Sparkle's documentation warns against.

A release made by hand on your Mac (above) can be offered as an update too: sign the disk image with `./bin/sign_update build/Kiri-<version>.dmg`, write the feed with `scripts/appcast.py` and attach both to a release here. The workflow is simpler.

## Crash reports

Kiri reports crashes and hangs to [Vaka](https://vaka.hellsoft.se), project `kiri-macos` (`App/Kiri/Telemetry.swift`; what is collected is on the website's privacy page, `site/privacy.html`). Release builds are stripped, so reports arrive as addresses; the release job uploads the build's dSYMs for the tag's version, which turns them into function names, files and lines. Without the `VAKA_TOKEN` secret it only warns. For a release made by hand, upload them yourself:

```sh
for f in build/DerivedData/Build/Products/Release/*.dSYM/Contents/Resources/DWARF/*; do
  curl -H "Authorization: Bearer $VAKA_TOKEN" --form-string kind=native --form-string release=<version> \
    -F "file=@$f" https://vaka.fly.dev/api/v1/projects/kiri-macos/artifacts
done
```
