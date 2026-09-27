<h1 align="center">portaki-release-action</h1>

<p align="center">
  <strong>Build, push to Portaki's registry, sign and announce a Portaki module from GitHub Actions</strong><br>
  One module, the one you point it at. No bash of your own.
</p>

<p align="center">
  <a href="https://github.com/PortakiApp/portaki-sdk"><img src="https://img.shields.io/badge/SDK-portaki--sdk-7C3AED" alt="portaki-sdk"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue.svg" alt="License Apache-2.0"></a>
  <a href="https://portaki.app"><img src="https://img.shields.io/badge/site-portaki.app-f59e0b" alt="portaki.app"></a>
</p>

---

```yaml
jobs:
  build:                      # no publishing rights: the module's code runs here
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: dtolnay/rust-toolchain@6bed0761d98439e5a578e2877258200ad565ba87 # stable
        with:
          targets: wasm32-unknown-unknown
      - uses: PortakiApp/portaki-release-action/build@v2

  release:                    # the publishing rights: nothing of the module runs here
    needs: build
    runs-on: ubuntu-latest
    environment: release
    permissions: { contents: read, id-token: write }
    steps:
      - uses: actions/checkout@v7
      - uses: PortakiApp/portaki-release-action@v2
```

`build@v2` runs the module's tests and conformity suite, builds it for `wasm32`, lints its
manifest and packages the OCI artifact — without any right to publish — then uploads it. The
release action downloads that artifact, audits `Cargo.lock`, pushes the artifact to **Portaki's
OCI repository** with a short-lived push right the registry grants, signs it keylessly with its
provenance and audit report, announces it, and writes a row into the run summary — running no
module code and no cargo. The full file is [`examples/single-module.yml`](examples/single-module.yml).

### Why two jobs

A module's `build.rs` and its tests are code its author wrote. Run in a job that holds
`id-token: write`, that code can request the job's OIDC token — the identity the artifact is
signed with and published under. The release job therefore runs nothing of the module: it reads
the sources (`Cargo.lock`, changelog, `listing.json`) and pushes what `build` produced, after
checking that it names the module, version and SDK of the sources.

## What it does not do

**It does not orchestrate a monorepo.** A repository holding several modules builds its own
matrix: it knows its parallelism limits, its environments and its publication order better than
this action does. Deciding for the caller would lock them into one layout.

What this repository provides is tools — [`portaki ci modules`](https://github.com/PortakiApp/portaki-sdk)
answers *which modules*, and the action releases the one you name. See
[`examples/monorepo.yml`](examples/monorepo.yml) for the matrix shape.

## Actions

| Action | Job | Role |
|--------|-----|------|
| `PortakiApp/portaki-release-action/build@v2` | `build` — no rights | Test, build, lint and package the module in `working-directory`, then upload the artifact |
| `PortakiApp/portaki-release-action@v2` | `release` — `id-token: write` | Audit `Cargo.lock`, push the artifact to Portaki's OCI repository, sign it, announce it |
| `PortakiApp/portaki-release-action/install@v2` | any | Install the Portaki CLI, and nothing else |
| `PortakiApp/portaki-release-action/audit@v2` | any | Run `cargo audit` on the module's `Cargo.lock` and write the report |

`install` is separate because a workflow often wants the CLI on its own — to list modules
(`portaki ci modules`), to run `portaki ci check` in a job that does not publish.

## Inputs

`build`:

| Input | Default | Meaning |
|-------|---------|---------|
| `working-directory` | `.` | The module — its crate root |
| `channel` | `stable` | The channel it is headed for — `stable` refuses an SDK older than 8.0.0 |
| `cli-version` | `auto` | Exact CLI version, or the SDK version this checkout resolves to |
| `check` | `true` | Warn about an outdated SDK or a manifest the shell has moved past |
| `artifact` | `portaki-module` | Name of the uploaded artifact — one per module in a matrix |

Release (the main action):

| Input | Default | Meaning |
|-------|---------|---------|
| `working-directory` | `.` | The module — its crate root |
| `artifact` | `portaki-module` | The artifact `build` uploaded |
| `channel` | `stable` | Registry channel the publication is announced on |
| `api-url` | *(empty)* | Platform to publish to; empty means production |
| `cli-version` | `auto` | Exact CLI version, or the SDK version this checkout resolves to — prebuilt only |
| `audit-fail-on` | `critical` | Lowest `cargo audit` severity that fails the release — see [the audit](#the-dependency-audit) |
| `dry-run` | `false` | Check the artifact against the sources, without pushing or announcing |
| `summary` | `true` | Append a row to the run summary |
| `report` | `true` | Tell Portaki how the run ended, so a broken module raises an alert and a fixed one clears it |

Outputs: `id`, `version`, `outcome` (`published`, `draft`, `already-published`, `dry-run`,
`failed`), `digest` and `reference` (`oci://<host>/modules/<id>@<digest>`, as announced).

The run report runs on **every** outcome, not only failures: conditioned on failure it could
never *clear* an alert, and a module that has been fixed would keep its own indefinitely. It
stores nothing on your side, and a report that fails never fails the job.

## How the CLI version is chosen

`cli-version: auto` reads the **`Cargo.lock`** nearest the module, not its `Cargo.toml`: a module
may declare the SDK by semver, by git branch or by path, and only the lock says what will
actually compile.

The `release` job installs **only** the prebuilt binary below, and fails otherwise: it runs no
cargo, since a module's `rust-toolchain.toml` or `.cargo/config.toml` could redirect it. The
`build` job, which compiles the module anyway, installs in this order:

1. **Prebuilt binary** from the SDK's GitHub Release `v<version>` —
   `portaki-<version>-<target>.tar.gz`, for `x86_64-unknown-linux-gnu` (Linux X64 runners) and
   `aarch64-apple-darwin` (macOS ARM64 runners). Downloaded without a token, checked against the
   `.sha256` published next to it, and put on the `PATH` from `$RUNNER_TEMP/portaki-bin`. Seconds
   instead of ~2 minutes of compilation. These binaries come from the SDK's own release workflow,
   which compiles the SDK and nothing else — no module code, no cache.
2. **From crates.io** — `cargo install portaki-cli --version <version> --locked`, when the release
   has no binary (SDK versions released before the binaries existed), the runner has no supported
   target, `cli-version` is a range rather than an exact version, the download fails, or the
   binary does not start (a runner image older than the build's glibc). The
   [cache](#the-cache) applies to this path only.

An archive whose `.sha256` is missing or does not match **fails the step**: the binary is never
run, and there is no silent fallback that would hide a tampered release.

Building from crates.io rather than a clone of the SDK repository: a clone would cost a branch
resolution on every run, a cache invalidated by every commit to that branch, and a binary
matching no published release.

`v2` needs a CLI with `portaki ci build` and `portaki ci release` (portaki-sdk 8.10.0 or later).
With an older one each action says so in one line — raise the SDK your module resolves to, or
pin `cli-version`.

> One step reads the lockfile in shell, because nothing is installed yet. It duplicates what
> `portaki ci sdk-version` does properly — so the step right after the install compares the two
> and warns if they disagree. The duplication is guarded by an assertion, not by trust.

## Where the artifact goes, and how it is signed

The artifact goes to **Portaki's own OCI repository**, nowhere else. `portaki ci release` asks the
Portaki registry for a push right (`POST /registry/v1/publications/push-token`, with a
single-use credential exchanged for the job's OIDC token): 15 minutes, this module and version
only, for the repository `modules/<id>` of the OCI host the answer names. No GHCR, no
`packages: write`, no registry secret.

Portaki production runs a module only if its digest carries a valid signature from the workflow
linked to that module. In the same job, [cosign](https://github.com/sigstore/cosign) v3.1.3
attests the pushed digest **without a key**: the job's OIDC token is exchanged at Sigstore's
Fulcio for a short-lived certificate naming the repository, the commit, the workflow file and the
ref, recorded in the public Rekor log. Two attestations are attached: a
[SLSA v1 provenance](https://slsa.dev/provenance/v1) and the `cargo audit` report
(`https://portaki.app/attestations/cargo-audit/v1`). Then the version is announced as
`oci://<host>/modules/<id>@<digest>`; the registry verifies the certificate against the
repository and workflow of the module's link.

The action is **composite**, not a reusable workflow, on purpose: the certificate then names the
calling workflow (your `release.yml` or `ci.yml`), which is what the module's link records.

Why cosign rather than GitHub's `actions/attest-build-provenance`: GitHub attestations are only
available to private repositories on GitHub Enterprise Cloud, and a community module may well
live in a private repository on a free plan. cosign keyless works for every repository, and the
registry reads the same format.

The signing identity is the **job**. A malicious `build.rs` or test running in that job could
request the same token — which is why the module is built and tested by `build@v2`, in a job
without `id-token`, and the release job runs nothing of it. A private repository is named in the
public Rekor log when it signs; that is the price of a verifiable signature.

## The dependency audit

The release job runs [`cargo audit`](https://rustsec.org) (RustSec) on the `Cargo.lock` nearest
the module — a prebuilt, SHA-256-pinned `cargo-audit` binary that reads the lockfile and compiles
nothing. The report is written in `$RUNNER_TEMP`, **in the release job**: a report produced by the
build job would have passed through the module's code, which could rewrite it. It is attested
with the artifact; the registry keeps its summary, shown to reviewers and to the author.

Severity comes from the advisory's CVSS 3.x vector: `critical` ≥ 9.0, `high` ≥ 7.0, `medium` ≥
4.0, `low` below. `audit-fail-on` (default `critical`) is the lowest severity that fails the
release. An advisory without a CVSS 3 vector is `unknown` and only warns. Informational
advisories — `unmaintained`, `unsound`, `notice`, `yanked` — never fail a release.

## One publication at a time

Two jobs publishing the same version at once overwrite the same OCI tag in turn. The CLI refuses
to push a version the registry already holds, which covers a re-run — but two jobs starting
together both look before either announces.

That last case belongs to the workflow, so both examples set it:

```yaml
concurrency:
  group: portaki-release-${{ matrix.module }}
  cancel-in-progress: false     # queue, never interrupt a publication in flight
```

## Permissions

On the `release` job only — the `build` job needs none of them:

```yaml
permissions:
  contents: read
  id-token: write     # le droit de push, l'annonce et l'identité qui signe
```

No publication secret, no registry credential, no signing key. The token proves where it comes
from; the link registered in the dashboard decides what it may publish — so link the module to
its repository there before the first run. The `stable` channel additionally requires the
`environment:` declared in that link; without it the exchange is refused with
`environment_required`.

## From v1

- `packages: write` goes, and so does `registry:` — there is no registry to choose.
- The single-job shape (`build: true`) and `sign@v1` are gone: `build@v2` in a job without rights,
  then the main action in the job with `id-token: write`. It downloads the artifact itself.
- Outputs gain `reference`; `outcome` gains `draft`.

## Examples

- [`examples/single-module.yml`](examples/single-module.yml) — one repository, one module, two jobs
- [`examples/monorepo.yml`](examples/monorepo.yml) — your matrix, our tools, the same two jobs

## License

[Apache-2.0](LICENSE) · Copyright 2026 Syntax Labs
