# gaea-plugin-demo

The Gaea demo plugin, and the template every Gaea plugin starts from. It has two models:

- `demo-matmul`, a GPU matmul loop behind a helper (`x-gaea.demo.matmul`), which proves the plugin path end to end:
  build, sign, verify, launch, run, cancel;
- `demo-gradient` (0.3.0), a GPU-computed two-colour gradient that answers MES `image.generate` with real PNGs. It
  shows how an offer is declared (its `x-gaea.gradient_angle` option, limits, the `textToImage` surface its lane
  backs), and gives a host an offer whose images it can check byte for byte. It needs Gaea 0.2.0 (`min_gaea`).

It is built on
[GaeaPluginKit](https://github.com/xocialize-code/gaea-plugin-kit) and speaks the Gaea Plugin Protocol v1
(xocialize-code/gaea, `spec/GPP-1.md`).

## Layout

| Path | What |
|---|---|
| `Sources/gaea-demo-worker/main.swift` | The plugin, declared in code: identity, models, helpers. `manifest.json` is generated from it |
| `scripts/build-plugin.sh` | Build, generate the manifest, validate it, assemble the bundle, sign, verify, zip |
| `scripts/check-plugin.sh` | Drive the signed bundle over GPP like Gaea does, with every `.build` folder hidden |
| `scripts/release.sh` | All of the above, then notarize, staple where it applies, and publish the GitHub Release |
| `.github/workflows/release.yml` | Runs `release.sh` on a `v*` tag, or on demand for an existing tag |

The bundle:

```
demo.gaeaplugin/Contents/
  Info.plist                        CFBundleIdentifier = the manifest's id
  MacOS/gaea-demo-worker            the worker, MLX linked statically
  Resources/manifest.json           generated at build time; sealed by the signature
  Resources/mlx-swift_Cmlx.bundle   default.metallib; MLX finds it through the worker's main bundle
```

A release carries `demo-<version>.gaeaplugin.zip`, its `.sha256`, and `manifest.json`.

## Make a plugin from this template

**[AUTHORING.md](AUTHORING.md) is the guide for plugin authors.** It covers:
- making a repo from this template;
- declaring models, offers, lanes and footprints;
- building and checking;
- signing with your own Developer ID and notarizing in CI;
- releasing;
- what a Gaea operator sees when approving your team.

## Build and check locally

```bash
scripts/build-plugin.sh
```

```bash
scripts/check-plugin.sh
```

`GAEA_SPEC_ROOT` points at a checkout of xocialize-code/gaea (default `../gaea-mes-media-server`). `GAEA_PLUGIN_KIT_PATH`
builds against a local GaeaPluginKit checkout.

`check-plugin.sh` proves, on the signed bundle (its job and control are set in the block at its top):

- the signature passes Gaea's own check: strict, nested code, against a Developer ID requirement pinned to the
  manifest's team. `build-plugin.sh` signs with the keychain's Developer ID identity for that team (`SIGN_IDENTITY`
  overrides it);
- the worker launches under `Process.launchRequirement` and its hello matches the manifest, digest included;
- an MLX job runs on the GPU (`Device(gpu, 0)`) driven over GPP, and the session passes `validate.py --transcript`;
- with `.build` hidden, the metallib comes from the bundle: the same worker outside its bundle fails with "Failed to
  load the default metallib".

On a machine with no Metal device it checks only the signature, the launch and hello, and says so.

## Notarization

This section is for this repo, signed by team CFZS6RXUCP. AUTHORING.md, "Sign and notarize", is the same for your own
team. Gaea's own installer doesn't need notarization. It downloads without quarantine, verifies the signature and launches
with a launch requirement. Notarization covers zips that people side-load through a browser, and it adds defence in
depth. It needs credentials only the account holder can create.

### On this Mac (once)

1. Create an app-specific password for the Apple ID on team CFZS6RXUCP: account.apple.com → Sign-In and Security →
   App-Specific Passwords.
2. Store it as the notary profile the scripts use, `mlx-notary` (the fleet's shared profile, which DeckCraftNative's
   release also uses; skip this step where it already exists). It prompts for the password:

   ```bash
   xcrun notarytool store-credentials mlx-notary --apple-id <apple-id> --team-id CFZS6RXUCP
   ```

3. Check it:

   ```bash
   xcrun notarytool history --keychain-profile mlx-notary
   ```

After that, `scripts/release.sh` notarizes on its own (`NOTARIZE=auto`) and replaces a pre-release's assets in place.

### CI secrets

Export the certificate: Keychain Access → login → My Certificates → "Developer ID Application: Dustin Nielson
(CFZS6RXUCP)". Check that it has its private key, then Export… as `developer-id.p12` with a password. Then set these
secrets on each plugin repo:

| Secret | Value |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | `base64 -i developer-id.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | the export password |
| `NOTARY_APPLE_ID` | the Apple ID |
| `NOTARY_APP_PASSWORD` | the app-specific password |

```bash
base64 -i developer-id.p12 | gh secret set DEVELOPER_ID_P12_BASE64 -R xocialize-code/gaea-plugin-demo
```

```bash
gh secret set DEVELOPER_ID_P12_PASSWORD -R xocialize-code/gaea-plugin-demo
```

```bash
gh secret set NOTARY_APPLE_ID -R xocialize-code/gaea-plugin-demo
```

```bash
gh secret set NOTARY_APP_PASSWORD -R xocialize-code/gaea-plugin-demo
```

Then delete `developer-id.p12`. To notarize a release that went out signed only:

```bash
gh workflow run release -R xocialize-code/gaea-plugin-demo -f tag=v0.2.0 -f publish=true
```

Without `publish=true` a dispatched run builds, signs, checks and notarizes, then stops, and keeps the zip as the run's
`dist` artifact. That's how to try a change to the build on a runner:

```bash
gh workflow run release -R xocialize-code/gaea-plugin-demo --ref <branch>
```

CI builds on GitHub's `xcode-27` runner (Xcode 27, Swift 6.4). Swift 6.3.3 on the `macos-26` runner built workers
that segfault on macOS 27 when a model package pushes a task-local value of its own (Gaea AB-T-0418). `build-plugin.sh`
names Swift Build (`--build-system swiftbuild`), which compiles mlx-swift's `.metal` kernels where Xcode 26's native
build system skipped them, and the workflow installs the Metal toolchain it compiles them with (AB-T-0382).

## Licence

Apache-2.0 (G-21), like Gaea and GaeaPluginKit. The manifest's `license` is the plugin code's; each model keeps its
own weight licence in `models[].package.license`.
