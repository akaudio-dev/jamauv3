<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Releasing Jam AUv3

Signed, notarized macOS builds for direct distribution (no App Store), attached to a
GitHub Release. Signing keys never leave your machine — releases are built locally with
[`make-release.sh`](make-release.sh); only the resulting `.dmg` is uploaded.

## Prerequisites (one-time)

Requires a **paid Apple Developer Program** membership under team **`66U677JDPM`**
(Developer ID signing and notarization are not available to free accounts).

1. **Create a "Developer ID Application" certificate** under team `66U677JDPM` and install
   it in your login keychain. Easiest via Xcode:
   *Xcode → Settings → Accounts → (select the `66U677JDPM` team) → Manage Certificates →
   `+` → Developer ID Application.*
   Verify it's installed:
   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

2. **Store notarization credentials** in a keychain profile named `notary`. Create an
   app-specific password at <https://account.apple.com> (Sign-In & Security → App-Specific
   Passwords) first:
   ```bash
   xcrun notarytool store-credentials notary \
     --apple-id <your-apple-id-email> --team-id 66U677JDPM
   ```
   (Paste the app-specific password when prompted.)

## Cut a release

1. Bump the version: set `MARKETING_VERSION` in `jamauv3.xcodeproj` (Xcode → target →
   General → Version), commit, and push.

2. Build the signed + notarized DMG (version defaults to `MARKETING_VERSION`):
   ```bash
   ./make-release.sh            # or: ./make-release.sh 1.0
   ```
   This archives, exports with Developer ID signing, builds `dist/JamAUv3-<version>.dmg`,
   notarizes it (waits for Apple), staples the ticket, and runs a Gatekeeper check.

3. Tag and publish the GitHub Release with the DMG attached:
   ```bash
   VERSION=1.0
   git tag -a "v$VERSION" -m "Jam AUv3 $VERSION"
   git push github "v$VERSION"
   gh release create "v$VERSION" "dist/JamAUv3-$VERSION.dmg" \
     -R akaudio-dev/jamauv3 \
     --title "Jam AUv3 $VERSION" \
     --notes "See the changelog for what's new."
   ```

## Verify the download

On a Mac that has never seen the app (or after removing the quarantine attr), confirm
Gatekeeper accepts it:
```bash
spctl --assess --type open --context context:primary-signature -v /Applications/Jam\ AUv3.app
xcrun stapler validate dist/JamAUv3-<version>.dmg
```

## Notes

- `dist/` is a build output — keep it out of git (it already is).
- The AUv3 extension is embedded in the app bundle; installing the notarized app (drag to
  `/Applications`) registers the plugin with the system for DAWs.
- `build-and-install.sh` is the *development* installer (unsigned, local); `make-release.sh`
  is the *distribution* build. Don't mix them.
