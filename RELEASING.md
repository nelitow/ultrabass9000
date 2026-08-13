# Releasing

Every push to `main` runs [`.github/workflows/release.yml`](.github/workflows/release.yml):
generate the Xcode project, run the test suite, and — if that passes — publish a GitHub
Release with the built `.app` attached as a zip. You can also trigger it manually from
the Actions tab (`workflow_dispatch`).

Nothing here needs a secret. It uses the automatic `GITHUB_TOKEN`.

## Versioning

The tag is derived, not hand-set: `scripts/derive-version.sh` reads `MARKETING_VERSION`
out of `project.yml` (currently `0.1.0`) and appends the commit count on `main`
(`git rev-list --count HEAD`), e.g. `v0.1.0-42`. That makes every commit's tag unique and
reproducible from a plain checkout, without depending on the Actions run number (which
would reset if the workflow file were ever deleted and recreated).

The commit count is only meaningful as a tiebreaker on `main`'s own history. A manual
`workflow_dispatch` run against some other branch will count that branch's commits
instead, which could in theory land on the same number `main` already used at a similar
depth — harmless in practice because the "already released" check below skips rather
than overwrites, but worth knowing if a dispatched run's release is skipped unexpectedly.

If a run's derived tag already has a release (e.g. a re-run, or a merge that didn't
change source), the workflow **skips the release steps and succeeds** rather than
failing — see the "Check whether this tag was already released" step.

Bump `MARKETING_VERSION` in `project.yml` yourself when you want the version number to
move; the pipeline never writes to `project.yml`.

## What gets built

`xcodebuild -scheme UltraBass9000 -configuration Release ... test`, which — because
`UltraBass9000Tests` depends on the `UltraBass9000` target — also produces the Release
`.app` as a side effect. One compile, both jobs; there's no separate `build` invocation.

## Signing in CI — and why the release is unsigned

`project.yml` sets `CODE_SIGN_STYLE: Automatic` with `DEVELOPMENT_TEAM: YUU5HHCFJD`. That
identity lives only on the developer's machine — a CI runner has no access to it, and
this repo intentionally never puts a Developer ID certificate in Actions secrets. So the
workflow overrides signing on the command line instead of touching `project.yml`:

```
CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM=""
```

After the build, `scripts/package-app.sh` applies one more thing: an **ad-hoc** signature
(`codesign --force --deep --sign -`) over the whole bundle before zipping. That's not a
Developer ID signature and doesn't change anything about the warning below — it exists
only so the "right-click → Open" Gatekeeper bypass documented below reliably works on the
downloaded bundle instead of being a hopeful suggestion. It was verified locally: an
ad-hoc-signed bundle round-tripped through `ditto`/unzip passes `spctl -a -t exec`.

### The Gatekeeper warning (goes in every release body too)

Because the release is unsigned and unnotarized, macOS will refuse to open it on any
other Mac and say **"UltraBass9000.app is damaged and can't be opened."** That message is
misleading — the app isn't damaged. To open it:

1. Unzip the release asset.
2. Right-click (Control-click) `UltraBass9000.app` → **Open** → confirm **Open** in the
   dialog.
3. If macOS doesn't offer an "Open" option, remove the quarantine attribute from
   Terminal instead: `xattr -dr com.apple.quarantine /path/to/UltraBass9000.app`.

`scripts/release-notes.sh` puts this same text at the top of every release body, since
that's the first (and possibly only) place a downloader will see it.

### Known limitation: unsigned release builds are functionally silent

This is a separate, more serious problem than Gatekeeper, and it is specific to this
app. From `project.yml`:

> A real signing identity is not optional here. Ad-hoc signed builds run, but TCC never
> prompts for audio capture and the process tap silently returns nothing but zeros.

In other words: once a downloader gets past the Gatekeeper warning above, the app will
launch and show its UI — but because it has no real Developer Team identity, macOS's TCC
privacy system never shows the audio-capture permission prompt, and the Core Audio
process tap this app is built around returns silence. **The app will appear to work and
produce no audio.** This isn't a CI bug to fix; it's the direct consequence of shipping
an unsigned build of an app whose entire feature set depends on a system permission that
unsigned code can't be granted. There is no ad-hoc-signing workaround for this part —
only a real Developer ID identity fixes it, and CI doesn't have one.

Until real signing exists, treat this release pipeline as producing installable-and-
inspectable builds, not yet a build you'd recommend to someone for daily use. Say so if
you link this from the landing page.

### What it would take to fix properly

- A **Developer ID Application** certificate (paid Apple Developer Program membership,
  $99/yr) exported as a `.p12`, plus its password, stored as repo secrets
  (`APPLE_CERTIFICATE_P12`, `APPLE_CERTIFICATE_PASSWORD` or similar) and imported into a
  CI keychain at build time.
- **Notarization**: an App Store Connect API key (issuer ID, key ID, `.p8`) stored as
  secrets, and a `xcrun notarytool submit --wait` + `xcrun stapler staple` step after
  signing.
- At that point `CODE_SIGN_STYLE: Automatic` in `project.yml` can likely stay as-is for
  local builds; CI would instead set `CODE_SIGN_IDENTITY="Developer ID Application: ..."`
  explicitly and skip the "disable signing" overrides this workflow currently uses.

None of that is set up. This document exists so whoever does it later knows exactly what
"later" needs.

## The runner: can a GitHub-hosted machine actually build this today?

**Yes, as of when this was written (2026-08-13).** This project needs the macOS 26 SDK
(`project.yml`: `MACOSX_DEPLOYMENT_TARGET: "26.0"`, `deploymentTarget.macOS: "26.0"`).
Checked directly against the `actions/runner-images` `macos-26` image README rather than
assumed:

- `macos-26` graduated from public preview to **generally available** on 2026-02-26
  ([GitHub changelog](https://github.blog/changelog/2026-02-26-macos-26-is-now-generally-available-for-github-hosted-runners/)).
- The image's OS is macOS 26.6, with Xcode versions 26.0.1 through 26.6 installed and
  **Xcode 26.6 (build 17F113) as the default** — the exact same build installed on the
  machine this pipeline was set up on.
- Installed SDKs span macOS 26.0 through 26.5, which covers this project's `26.0`
  deployment target.
- `macos-latest` also resolved to `macos-26` as of the June–July 2026 rollover
  ([tracking issue](https://github.com/actions/runner-images/issues/14167)), but the
  workflow pins `runs-on: macos-26` explicitly rather than relying on that, so a future
  label rollover can't silently change what SDK is available.

The workflow doesn't just trust this, though — its first real step
(`Verify macOS 26 SDK is available`) greps `xcodebuild -showsdks` for `macosx26` and fails
the run with a clear error if a future runner image regresses. If that ever fires, this
paragraph is stale; check the current `macos-26-Readme.md` in `actions/runner-images` and
update `runs-on:` if a different label is now the right one.

**Cost note:** this is a private repository, and GitHub bills macOS Actions minutes at a
significantly higher per-minute multiplier than Linux. A build+test run here is not free
against the included minutes quota — worth knowing before merging frequently to `main`.

## Linking to "latest release" from a landing page

The zip's filename changes every release (it embeds the version and commit count), so a
hardcoded direct-download URL will go stale. Two options that stay correct automatically:

- Link to `https://github.com/nelitow/ultrabass9000/releases/latest` and let the visitor
  click the asset — simplest, no code needed on the landing page.
- If you want a real "click to download the app" button instead of a GitHub page, call
  `GET https://api.github.com/repos/nelitow/ultrabass9000/releases/latest` from the
  landing page's build or backend and use `assets[0].browser_download_url` from the
  response. Since this is a **private repo**, that API call needs an authenticated
  request (a token with `repo` read scope) — an unauthenticated call will 404, and the
  browser_download_url itself also requires auth to fetch from a private repo. Making the
  repo public, or proxying the download through something authenticated, is a
  prerequisite for a landing page to actually serve the file to the public.

## Running the same steps locally

```sh
xcodegen generate
xcodebuild -project UltraBass9000.xcodeproj -scheme UltraBass9000 \
  -configuration Release -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM="" \
  test

./scripts/derive-version.sh
./scripts/package-app.sh build/Build/Products/Release/UltraBass9000.app build/UltraBass9000-local.zip
```

That reproduces exactly what CI ships, including the ad-hoc signature, so you can check
`spctl -a -t exec -vv build/Build/Products/Release/UltraBass9000.app` yourself before
trusting a release.

## Manual setup checklist (one-time, for the repo owner)

- [ ] Actions is already enabled on this repo (confirmed via `gh api
      repos/nelitow/ultrabass9000/actions/permissions` while writing this pipeline —
      `enabled: true`, `allowed_actions: all`). Nothing to do here.
- [ ] **Workflow permissions — action required, confirmed via `gh api
      repos/nelitow/ultrabass9000/actions/permissions/workflow`: currently
      `"default_workflow_permissions": "read"`.** This workflow's own
      `permissions: contents: write` can only narrow that ceiling, not raise it — with
      the repo stuck on read-only, the "Create GitHub release" step will 403 the first
      time this runs. Go to Settings → Actions → General → "Workflow permissions" and
      select **"Read and write permissions"**, then save.
- [ ] Nothing to add under Settings → Secrets — this pipeline doesn't use any.
- [ ] Decide whether/when to invest in real signing (see above) before pointing a public
      landing page at this pipeline's output, given the "functionally silent" limitation.
