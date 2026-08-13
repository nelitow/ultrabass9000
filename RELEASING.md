# Distribution

UltraBass 9000 is distributed as source. There is no downloadable build, and that is a deliberate
choice rather than an unfinished one.

## Why there is no binary

macOS grants audio-capture permission only to properly signed builds. An ad-hoc signed build (which
is all CI can produce without a paid Apple Developer account) launches, looks completely normal,
shows its meters, and captures nothing at all. The failure is silent and looks like a bug in the
app rather than a signing problem, so publishing one would waste the time of everyone who tried it.

Building locally sidesteps this entirely. Xcode signs the app with your own development identity, so
macOS prompts for permission the first time you run it and everything works.

## Continuous integration

`.github/workflows/ci.yml` builds and tests on every push and pull request. It does not publish
anything. Signing is disabled for that build, which is fine because nothing there ever needs to
capture audio.

The workflow pins `runs-on: macos-26` because the project targets macOS 26.0 and needs a matching
SDK. It fails with an explicit message if the runner image stops providing one, rather than failing
later and more confusingly.

## What a signed release would take

If this is ever worth distributing as a binary:

1. An Apple Developer Program membership, for a Developer ID Application certificate.
2. That certificate exported as a `.p12`, with its password, stored as repository secrets, and a
   step that imports it into a temporary keychain on the runner.
3. Notarisation after signing: `xcrun notarytool submit --wait`, then `xcrun stapler staple`, using
   an App Store Connect API key also held as secrets.
4. Packaging into a `.dmg` or a zip made with `ditto -c -k --keepParent`, which preserves the bundle
   metadata that `zip` discards.

Without step 3, Gatekeeper refuses to open the app on any other Mac and reports it as damaged, which
is a separate problem from the permission one above and equally worth avoiding.
