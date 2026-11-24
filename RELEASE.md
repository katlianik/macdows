# Macdows release checklist

For every public build:

1. Update `CFBundleVersion` in `Macdows.app/Contents/Info.plist`.
2. Compile and run `test.m`.
3. Build, Developer ID sign, notarize and staple the universal application and DMG.
4. Run `./package-source.sh <build-number> <output-directory>`.
5. Publish the matching `Macdows.dmg` and `Macdows-1.35-source.zip` together.
6. Update the build number, release description and both download links in the website files `index.html`, `index.md` and `llms.txt`. Sync the public page source and assets to the repository’s `website/` directory.
7. Verify the downloaded public DMG and source ZIP hashes against the local release artifacts.
   Set the version and verified DMG SHA-256 in `Casks/macdows.rb` before tagging. After publishing the release, verify the cask fetches the final DMG.
8. Keep the menu descriptions, website Updates section, and CHANGELOG.md in sync. Tag the matching source commit as `vVERSION-buildNUMBER` and publish a GitHub Release with both verified artifacts and their SHA-256 hashes.

The public source archive must match the public binary build. Do not include local test binaries, Xcode archives, signing material, credentials or user data.
