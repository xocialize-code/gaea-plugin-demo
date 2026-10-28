# gaea-plugin-demo

The Gaea demo plugin, and the template every Gaea plugin starts from. It is a GPU matmul loop that proves the plugin
path end to end: build, sign, verify, launch, run, cancel. It is built on
[GaeaPluginKit](https://github.com/xocialize/gaea-plugin-kit) and speaks the Gaea Plugin Protocol v1
(xocialize/gaea, `spec/GPP-1.md`).

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

1. Copy this repo to `gaea-plugin-<family>` (G-11).
2. In `main.swift`, change the identity (`id`, `version`, `repo`, `title`, `executable`).
3. Replace `demo-matmul` with your models. An MLXEngine package is
   `.engine(YourPackage.self, id:, title:, lanes:, operations:)`: one lane per configuration (usually per quant), and
   one `EngineOperation` per MES operation, mapping the job's params onto the canonical request. A model the engine has
   no capability for is `.custom(...)` with a `PluginModel`, as here.
4. Declare `offers` (and `helpers`, `settings`, `storage`).
5. Rename the product in `Package.swift` and `PRODUCT` in `scripts/build-plugin.sh`.

## Build and check locally

```bash
scripts/build-plugin.sh
```

```bash
scripts/check-plugin.sh
```

`GAEA_SPEC_ROOT` points at a checkout of xocialize/gaea (default `../gaea-mes-media-server`). `GAEA_PLUGIN_KIT_PATH`
builds against a local GaeaPluginKit checkout.

`check-plugin.sh` proves, on the signed bundle:

- the signature passes Gaea's own check: strict, nested code, against a Developer ID requirement pinned to team
  CFZS6RXUCP, the only team Gaea v1 trusts (G-22). The template signs with that team and nothing overrides it;
- the worker launches under `Process.launchRequirement` and its hello matches the manifest, digest included;
- an MLX job runs on the GPU (`Device(gpu, 0)`) driven over GPP, and the session passes `validate.py --transcript`;
- with `.build` hidden, the metallib comes from the bundle: the same worker outside its bundle fails with "Failed to
  load the default metallib".

On a machine with no Metal device it checks only the signature, the launch and hello, and says so.

## Notarization

Gaea's own installer doesn't need notarization. It downloads without quarantine, verifies the signature and launches
with a launch requirement. Notarization covers zips that people side-load through a browser, and it adds defence in
depth. It needs credentials only the account holder can create.

### On this Mac (once)

1. Create an app-specific password for the Apple ID on team CFZS6RXUCP: account.apple.com → Sign-In and Security →
   App-Specific Passwords.
2. Store it as the notary profile the scripts use (it prompts for the password):

   ```bash
   xcrun notarytool store-credentials gaea-notary --apple-id <apple-id> --team-id CFZS6RXUCP
   ```

3. Check it:

   ```bash
   xcrun notarytool history --keychain-profile gaea-notary
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
| `GAEA_REPOS_TOKEN` | a fine-grained token with read-only Contents on xocialize/gaea and xocialize/gaea-plugin-kit (both private) |

```bash
base64 -i developer-id.p12 | gh secret set DEVELOPER_ID_P12_BASE64 -R xocialize/gaea-plugin-demo
```

```bash
gh secret set DEVELOPER_ID_P12_PASSWORD -R xocialize/gaea-plugin-demo
```

```bash
gh secret set NOTARY_APPLE_ID -R xocialize/gaea-plugin-demo
```

```bash
gh secret set NOTARY_APP_PASSWORD -R xocialize/gaea-plugin-demo
```

```bash
gh secret set GAEA_REPOS_TOKEN -R xocialize/gaea-plugin-demo
```

Then delete `developer-id.p12`. To notarize a release that went out signed only:

```bash
gh workflow run release -R xocialize/gaea-plugin-demo -f tag=v0.2.0
```

## Licence

Apache-2.0 (G-21), like Gaea and GaeaPluginKit. The manifest's `license` is the plugin code's; each model keeps its
own weight licence in `models[].package.license`.
