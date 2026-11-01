# Writing a Gaea plugin

This guide takes you from an empty repo to a plugin that a Gaea server installs, approves and runs. You start from
this repo, the demo plugin, which is also the template.

- [What a plugin is](#what-a-plugin-is)
- [What you need](#what-you-need)
- [1. Make your repo from the template](#1-make-your-repo-from-the-template)
- [2. Declare the plugin](#2-declare-the-plugin)
- [3. Lanes, footprints and how Gaea learns peaks](#3-lanes-footprints-and-how-gaea-learns-peaks)
- [4. Build and check it](#4-build-and-check-it)
- [5. Sign and notarize](#5-sign-and-notarize)
- [6. Release](#6-release)
- [7. Run it in Gaea](#7-run-it-in-gaea)
- [8. Updates](#8-updates)
- [When something fails](#when-something-fails)

## What a plugin is

- **A bundle.** A plugin is a signed `.gaeaplugin` bundle: one worker executable, a `manifest.json`, and the resource
  bundles it links:

  ```
  <name>.gaeaplugin/Contents/
    Info.plist                       CFBundleIdentifier = the manifest's id
    MacOS/<executable>               your worker
    Resources/manifest.json          generated from your code at build time, sealed by the signature
    Resources/mlx-swift_Cmlx.bundle  MLX's default.metallib (and any other SwiftPM resource bundle you link)
  ```

- **A process of its own.** Gaea runs each plugin as its own process. They talk over stdin and stdout in the Gaea
  Plugin Protocol, GPP-1: one JSON object per line ([`spec/GPP-1.md`](https://github.com/xocialize-code/gaea/blob/main/spec/GPP-1.md)
  in xocialize-code/gaea).
- **The kit speaks the protocol.** You don't write GPP yourself.
  [GaeaPluginKit](https://github.com/xocialize-code/gaea-plugin-kit) runs the protocol loop, generates the manifest from
  your Swift declaration, and gives you `gaea-plugin-check`, a tiny host for testing. You write models: a `prepare`,
  a `run` and an `unload`.
- **How clients reach it.** Clients talk to Gaea in MES (the Media Engine Spec), never to your plugin. An **offer** in
  your manifest says which MES operation a model answers (`image.generate`, `audio.speak`, `video.upscale`, …) and with
  which options. Gaea checks each request against the offer, picks the model and lane, admits it to memory, and sends
  your worker a `run`.
- **How Gaea finds and trusts it.** An operator adds your plugin to Gaea by its GitHub repo URL. Gaea reads the repo's
  releases, downloads the zip, and checks:
  - the sha256;
  - the signature: Developer ID, hardened runtime, sealed;
  - that the manifest matches the signature and the release.

  Trust comes from your **signature, never the URL**. The first time Gaea meets your Developer ID team it **holds**
  the release and asks the operator (section 7).

## What you need

- **A Mac with Apple silicon**, on macOS 26 or later, with Xcode 26 or later.
- **Xcode's Metal toolchain**, which MLX compiles its kernels with:

  ```bash
  xcodebuild -downloadComponent MetalToolchain
  ```

- **An Apple Developer Program membership**, with a **Developer ID Application** certificate in your login keychain.
  Your Team ID is the ten characters in brackets in its name, for example
  `Developer ID Application: Jane Doe (ABCDE12345)`. To list yours:

  ```bash
  security find-identity -v -p codesigning
  ```

- **For notarizing:** an app-specific password for your Apple ID (account.apple.com → Sign-In and Security →
  App-Specific Passwords).
- **A GitHub repo** for the plugin (public, or private: see section 7). Name it `gaea-plugin-<family>`, for example
  `gaea-plugin-sketch`. You also need the `gh` CLI, signed in.
- **A checkout of [xocialize-code/gaea](https://github.com/xocialize-code/gaea)**, which holds the manifest schemas
  and `tools/validate.py`. The build uses them. Clone it next to your repo as `gaea-mes-media-server`, or point
  `GAEA_SPEC_ROOT` at it:

  ```bash
  git clone https://github.com/xocialize-code/gaea ../gaea-mes-media-server
  ```

- **To run it, Gaea 0.13.0 or later.** That's the first version that holds a new team's release for the operator.
  Older versions refuse any team but Gaea's own.

## 1. Make your repo from the template

1. Copy this repo's files into your new repo, without its history:

   ```bash
   git clone --depth 1 https://github.com/xocialize-code/gaea-plugin-demo gaea-plugin-sketch
   ```

   ```bash
   cd gaea-plugin-sketch && rm -rf .git && git init -b main
   ```

2. **Rename the worker.** Its name is `gaea-<family>-worker`.
   - Move `Sources/gaea-demo-worker` to `Sources/gaea-sketch-worker`.
   - In `Package.swift`, rename the package (`gaea-plugin-sketch`) and the executable target.
3. **Name the bundle.** In each of `scripts/build-plugin.sh`, `scripts/check-plugin.sh` and `scripts/release.sh`, change
   the `NAME` default (`demo`) to your bundle's short name (`sketch`). In `build-plugin.sh`, set `PRODUCT` to the
   target's name.
4. **Edit `main.swift`** (section 2). Replace the demo's two models with yours, or start by renaming one of them.
5. **Rewrite `README.md`** for your plugin, and keep a link to this guide.
6. **Keep the licence, or replace it.** `LICENSE` is Apache-2.0. The manifest's `license` is your plugin code's.
   Each model declares its weights' licence separately.

`Package.swift` takes GaeaPluginKit `from: "0.10.0"`: 0.10.0 is the first kit that accepts a team other than Gaea's
own. If your model is an MLX Swift package, add it as a dependency too. To work on the kit and your plugin together,
set `GAEA_PLUGIN_KIT_PATH` to a local checkout of the kit.

## 2. Declare the plugin

Everything about the plugin is declared in Swift, in `main.swift`. `scripts/build-plugin.sh` runs the worker with
`--manifest` to write `manifest.json` from that declaration, then checks the result with `tools/validate.py`. You never
edit the manifest by hand.

### Identity

```swift
let plugin = GaeaPluginDefinition(
    id: "com.example.gaea.sketch",          // reverse DNS; also the bundle id and the signing identifier
    version: "0.1.0",                        // semver; the release tag is v<version>
    minGaea: "0.13.0",                       // the oldest Gaea that can run it
    team: "ABCDE12345",                      // YOUR Team ID, the one on your Developer ID certificate
    repo: "https://github.com/you/gaea-plugin-sketch",  // the repo operators add it from
    title: "Sketch",
    summary: "One sentence on what it adds.",
    license: "Apache-2.0",                   // your code's licence (SPDX)
    executable: "gaea-sketch-worker",        // the executable target's name
    models: [ … ],
    offers: [ … ],
    helpers: [ … ])

await GaeaPluginMain.run(plugin)
```

These fields have to agree with things outside the code:
- **`team`** must be your certificate's team. The build signs with the identity of that team, and Gaea refuses a
  bundle whose signature doesn't match the manifest's team.
- **`repo`** must be the repo the operator adds. Gaea refuses a release whose manifest names another repo.
- **`version`** must match the release tag, `v<version>`.

### Models

A model is either:
- **`.engine(Package.self, id:, title:, lanes:, operations:)`**: a model that is an MLXEngine package (a Swift port
  wrapped as a `ModelPackage`). The kit's engine loads it, budgets its memory and runs it. Each `EngineOperation` maps
  an MES operation's params onto the package's canonical request. `gaea-plugin-z-image` is an example.
- **`.custom(id:, title:, manifest:, lanes:, make:)`**: your own code, as a class that conforms to `PluginModel`. Both
  demo models are custom:

```swift
final class SketchModel: PluginModel, @unchecked Sendable {
    func prepare(lane: LaneDefinition, context: WorkerContext) async throws { /* load weights for this lane */ }
    func unload() async { Memory.clearCache() }

    func run(_ job: Job, context: RunContext) async throws -> RunResult {
        guard job.operation == "image.generate" else { throw GPPError(.unsupportedOperation, "sketch only generates.") }
        let prompt = try job.input("prompt").map { try String(contentsOf: $0, encoding: .utf8) } ?? ""
        let size = job.param("size")                      // MES params, with the offer's defaults filled in
        let style = job.param("x-sketch.style")?.stringValue ?? "pencil"   // an x- param your offer declares
        // … work, calling context.checkCancellation() and context.progress("render", step: i, of: n) as you go …
        let url = job.outputDir.appending(path: "image-0.png")
        // … write the PNG to url …
        return RunResult(outputs: [.file("images", url, mediaType: "image/png")],
                         effective: ["size": …, "seed": .int(job.seed ?? 0), "x-sketch.style": .string(style)],
                         warnings: [])
    }
}
```

How a job reaches `run`:
- **Inputs arrive as files**, even text. An MES `prompt` is a UTF-8 `.txt` file (`job.input("prompt")`), an image is
  its file, and several values arrive as a list (GPP-1 §3.3).
- **Outputs are files you write under `job.outputDir`.** Name them by the MES output (`images`, `audio`, `video`), or
  return `.value(name, …)` for data.
- **`effective`** reports what you actually used, such as the size after snapping to your grid, the seed and the
  steps. Gaea merges it into the MES result.
- **A warning** tells the client you did something other than asked: `Warning(code: "size_snapped", message:,
  param: "size")`.
- **A refusal** is a `GPPError`, for example `GPPError(.invalidRequest, "size is 64–2048 on each side.")`. The codes
  are in GPP-1 §3.5: `invalid_request`, `unsupported_operation`, `unknown_model`, `out_of_memory`, `model_error` and
  `cancelled`.
- **A cancel** arrives as a `CancellationError` from `context.checkCancellation()`. Check at every step.
- **Seeds:** if your model is random, seed it from `job.seed`, so the same request makes the same output.

Each model also carries a `PackageManifest` (MLXToolKit): its weight licence, provenance, footprints (section 3), the
backends it needs (`.metalGPU`), and its surfaces (`ToolDescriptor`s with a capability such as `.textToImage`). A
`.custom` model with no surfaces can still be offered. The demo's `matmulManifest` and `gradientManifest` are complete
examples.

### Offers

An offer makes a model answer an MES operation. It's `PluginManifest.Offer`:
- **`operation` and `profile`:** for example `image.generate` in the `image` profile. The MES profile defines the
  standard params (`size`, `count`, `seed`, `quality`).
- **`model`:** the card clients see. It holds `id`, `title`, `license` (`spdx`, `commercial_use`, `terms_url`),
  `memory_class`, `speed_class`, `quality_tiers` and `notes`. A licence that needs the operator's or users'
  acceptance is declared here.
- **`params`:** a JSON Schema for your own options. Each key starts with `x-` (`x-sketch.style`), and clients see it
  as an MES extension. `x-mes-ui` gives the form widget, because plugins ship no UI code: Gaea renders forms from these
  descriptors.
- **`limits`:** `maxPixels`, `minSide`, `maxSide` and `sizeMultiple` for images, and duration and frame limits for
  audio and video. Gaea refuses a request outside them before your worker sees it.

**Helpers** are operations for Gaea or tools, not for MES clients, such as the demo's `x-gaea.demo.matmul`. Plugins
can also declare `settings` (operator settings, rendered as forms) and `storage` (a small key-value store Gaea keeps
for you, GPP-1 §3.6).

The full manifest rules are GPP-1 §4.

## 3. Lanes, footprints and how Gaea learns peaks

- **A lane is one way to load a model**, usually one quantization (`bf16`, `int8`, `int4`). Every model has exactly
  one **default** lane:

  ```swift
  lanes: [LaneDefinition(id: "int8", default: true, configuration: Int8Config()),
          LaneDefinition(id: "bf16", default: false, configuration: BF16Config())]
  ```

- **Each lane declares what it holds**, in the model's `PackageManifest`:

  ```swift
  requirements: RequirementsManifest(
      footprints: [QuantFootprint(quant: .int8, residentBytes: 6_400_000_000, peakActivationBytes: 2_100_000_000)],
      requiredBackends: [.metalGPU])
  ```

  - `residentBytes` is the weights once loaded.
  - `peakActivationBytes` is the most the lane adds while it runs, at your largest supported size.
  - A lane's need is their sum.
- **Gaea admits a job only when its lane's need fits** the server's memory budget, beside whatever else is loaded.
  Gaea evicts idle models to make room.
- **Fallback:** when the default lane doesn't fit, Gaea loads a smaller lane and warns the client. A request that names
  a lane never falls back.
- **Gaea measures your worker from outside** (`phys_footprint`, and its lifetime peak). After a run on a worker that
  has held only that lane, a peak past what you declared becomes the lane's need from then on:
  - Gaea records a `memory_learned` event against your plugin version;
  - the next admission charges the measured peak.

  An under-declared lane therefore gets admitted late, and squeezes other models until Gaea has learned its peak.
  Declare honestly: measure your largest case with `gaea-plugin-check` (it prints the worker's phys_footprint and
  peak), and round up.

## 4. Build and check it

```bash
scripts/build-plugin.sh
```

This script:
1. builds the worker (Release, arm64, Swift Build, which compiles MLX's `.metal` kernels);
2. writes `manifest.json` from your code and validates it;
3. assembles the bundle and copies in every resource bundle the worker links;
4. signs it with your team's Developer ID, with hardened runtime and a secure timestamp;
5. checks the signature against your team's requirement;
6. zips it, with a `.sha256`.

Everything lands in `dist/`.

```bash
scripts/check-plugin.sh
```

This drives the signed bundle the way Gaea does, with every `.build` folder hidden, so MLX can only find its metallib
inside the bundle. It runs `gaea-plugin-check`, which:
1. verifies the signature against the manifest's team;
2. launches the worker under a launch requirement the kernel enforces;
3. matches its `hello` to the manifest;
4. drives `configure` → `prepare` → `run` → `memory.query` → `shutdown`;
5. records the session, which `tools/validate.py --transcript` then checks.

Edit the block at the top of `check-plugin.sh` for your models:
- **`CHECK_ARGS`** is the job to send. For example:

  ```
  (--operation image.generate --model sketch --text prompt="a lighthouse" --params '{"size":{"width":512,"height":512}}' --seed 7)
  ```

  Other flags: `--lane <id>`, `--model-params '<json>'` for `x-` params, `--input <name>=<path>` for media, and
  `--models-root <dir>` to use weights already on disk. The comment at the top of the kit's
  `Sources/gaea-plugin-check/main.swift` lists them all.
- **`CHECK_EXPECT`** is text the output must contain to show real work happened. Leave it empty if the job succeeding
  is enough.
- **`CONTROL_RUN`** is one GPP `run` line for a control: the worker, copied outside its bundle, must fail to load the
  metallib. This proves the bundle carries its own. Leave it empty to skip the control.

**A golden check is worth having for a real model.** Add a second executable target, `<family>-inproc`, that calls the
same model code in-process. Then compare its output byte for byte with what the signed bundle returns through
`gaea-plugin-check`, for a few seeded cases. That catches anything the protocol path changes: params, seeding, file
encoding. `gaea-plugin-kokoro/scripts/golden.sh` and `gaea-plugin-rife/scripts/golden.sh` are complete examples.

## 5. Sign and notarize

Signing uses the identity whose team is the `team` in your code. `build-plugin.sh` finds it in your keychain, or you
can name it with `SIGN_IDENTITY`. If you have certificates from several teams, the manifest's team picks the right
one.

Gaea's own installer doesn't need notarization, because it checks the signature itself. Notarize anyway: a zip
downloaded in a browser needs it, and the operator sees "Notarized: yes" when approving your team.

**On your Mac (once).** Store the notary credentials as a keychain profile:

```bash
xcrun notarytool store-credentials mlx-notary --apple-id <your-apple-id> --team-id <TEAM> --password <app-specific-password>
```

`scripts/release.sh` then notarizes on its own. With `NOTARY_PROFILE` you can use another profile name.

**In CI.** `.github/workflows/release.yml` builds, signs, checks, notarizes and publishes on a pushed `v*` tag. It
needs four secrets, either on the repo or as organization secrets visible to it:

| Secret | Value |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | your Developer ID Application certificate and private key, exported as a .p12 (Keychain Access → My Certificates → Export), then `base64 -i developer-id.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | the .p12's export password |
| `NOTARY_APPLE_ID` | your Apple ID |
| `NOTARY_APP_PASSWORD` | the app-specific password |

To set them on the repo:

```bash
base64 -i developer-id.p12 | gh secret set DEVELOPER_ID_P12_BASE64 -R you/gaea-plugin-sketch
```

```bash
gh secret set DEVELOPER_ID_P12_PASSWORD -R you/gaea-plugin-sketch
```

```bash
gh secret set NOTARY_APPLE_ID -R you/gaea-plugin-sketch
```

```bash
gh secret set NOTARY_APP_PASSWORD -R you/gaea-plugin-sketch
```

Then delete the .p12. If your organization already has these as organization secrets, skip this step.

The workflow:
- imports the certificate into a temporary keychain;
- notarizes for that certificate's team;
- checks out xocialize-code/gaea for the validator;
- runs `scripts/release.sh`.

It fails at once if a secret is missing, so a release that skipped notarization never looks green. Runners have no
GPU, so CI checks the signature, the launch and the `hello`. Run `scripts/check-plugin.sh` on your Mac for the job
itself.

To try the whole pipeline without publishing anything, dispatch it on a branch:

```bash
gh workflow run release -R you/gaea-plugin-sketch --ref main
```

Without `publish=true` it stops after notarizing, and keeps the zip as the run's `dist` artifact.

## 6. Release

1. Set `version` in `main.swift`, and run `scripts/build-plugin.sh` and `scripts/check-plugin.sh` on your Mac.
2. Commit and push, then tag `v<version>` and push the tag:

   ```bash
   git tag v0.1.0 && git push origin main v0.1.0
   ```

3. Watch the run:

   ```bash
   gh run watch -R you/gaea-plugin-sketch
   ```

A release carries three assets, which Gaea needs all of:
- `<name>-<version>.gaeaplugin.zip`;
- its `.sha256`;
- `manifest.json`.

The tag must match the manifest's version, or the run stops. A version with a suffix (`0.2.0-rc.1`) is a pre-release
on GitHub. Gaea installs and offers updates only from full releases, unless the operator names the version.

## 7. Run it in Gaea

On the Gaea server's Mac, the operator adds your repo:

```bash
gaea plugins add https://github.com/you/gaea-plugin-sketch
```

Gaea picks the newest full release whose manifest it can run (its GPP version and `min_gaea`). Name a version to take
another one: `gaea plugins add <repo> 0.1.0`.

**A private repo** needs a token in Gaea's environment when Gaea starts, for example
`GAEA_GITHUB_TOKEN=$(gh auth token)`. Gaea uses it to read releases and never stores it. A public repo needs nothing.

### What the operator sees the first time

Your team is new to this server, so Gaea downloads and checks the release, then **holds** it:

```
Held h-06d0df71: Sketch 0.1.0 (com.example.gaea.sketch) is signed by a team Gaea doesn't trust yet.
  Signed by:  Developer ID Application: Jane Doe (ABCDE12345)
  Team:       ABCDE12345
  Notarized:  yes
  Repo:       https://github.com/you/gaea-plugin-sketch (v0.1.0)
  Models:     sketch
Trusting the team lets Gaea run any plugin it signs, including later updates.
  Approve: gaea trust approve h-06d0df71
  Decline: gaea trust decline h-06d0df71
```

In Gaea's console, Plugins → Add Plugin… shows the same thing as a "Trust Jane Doe?" sheet, with Trust and Install and
Don't Trust. What happens next:
- **Approved:** your team joins the server's trust list, and the plugin installs. Your later releases, and your other
  plugins, install without asking.
- **Declined:** the download is deleted.
- **Your team removed later** (`gaea trust remove ABCDE12345`): your plugins stop and stay installed until it's
  trusted again.

So make the hold easy to approve:
- the certificate's name should be one the operator recognizes;
- notarize;
- point the README at what the plugin does and where the weights come from.

`gaea trust` lists the trusted teams and anything held.

### Run a job

Your models are now offered over MES. For example, an image job on a Gaea serving this Mac on its default port:

```bash
curl -s -H 'MES-Version: 0.1' -H 'Content-Type: application/json' -X POST http://127.0.0.1:17630/mes/v0/jobs \
  -d '{"operation":"image.generate","model":"sketch","inputs":{"prompt":"a lighthouse at dusk"},"params":{"size":{"width":512,"height":512},"seed":7}}'
```

Then:
1. Poll `GET /mes/v0/jobs/<id>?wait=10` until its `state` is `holding`.
2. Fetch each `result.outputs[].href`.
3. Look at `result.effective.model_params["x-gaea.worker"]` for your plugin, version and lane.

Other useful commands:
- **`gaea models`** lists what's offered.
- **`gaea plugins logs <id>`** shows your plugin's events (installed, held, memory_learned) and your worker's stderr.
- **`gaea ledger`** shows what each worker is charged and holds.

## 8. Updates

1. Bump `version`, then tag and push it.
2. Gaea checks your repo's releases every few hours. The operator sees "update available" and runs
   `gaea plugins update <id>`.
3. Gaea installs the new version beside the old one, and switches when your models are idle. It keeps the old version
   for `gaea plugins rollback <id>`.

A release signed by another team (a new certificate from a different team, say) is held for approval again. A
renewed certificate from the same team isn't.

## When something fails

| Symptom | Cause |
|---|---|
| `team X isn't an Apple Team ID` when generating the manifest | `team:` in `main.swift` isn't ten capital letters or digits. |
| `no "Developer ID Application: … (TEAM)" identity in the keychain` | The certificate for the manifest's team isn't in your keychain. In CI, the p12 is from another team. |
| `Failed to load the default metallib` in the check | The bundle lacks `mlx-swift_Cmlx.bundle`. Build with `scripts/build-plugin.sh`, which uses Swift Build: Xcode 26's default build system skips the `.metal` kernels. |
| The worker traps at launch, only outside your Mac's build folder | A SwiftPM resource bundle is missing from `Contents/Resources`, so `Bundle.module` traps. `build-plugin.sh` copies every bundle from the bin folder. Rebuild with it, not by hand. |
| Gaea: `the manifest names team X but the bundle is signed by Y` | `team:` doesn't match the signing certificate. |
| Gaea: `the manifest's repo … isn't …, the repo it was added from` | `repo:` doesn't match the URL the operator added. |
| Gaea: `… has no release Gaea … can install` | A release lacks one of its three assets, needs a newer `min_gaea`, or is a pre-release (name the version). |
| `tag … doesn't match the manifest version` in CI | Tag `v<version>`, the same as `main.swift`. |

The protocol itself, its messages, errors and versioning, is
[GPP-1](https://github.com/xocialize-code/gaea/blob/main/spec/GPP-1.md). Its schemas are in `schemas/v1/` of
xocialize-code/gaea, and `tools/validate.py` checks a manifest or a session against them.
