<h1 align="center">portaki-release-action</h1>

<p align="center">
  <strong>Build, lint, publish and announce a Portaki module from GitHub Actions</strong><br>
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
      - uses: PortakiApp/portaki-release-action@v1
        with: { dry-run: true, report: false, summary: false }
      - uses: actions/upload-artifact@v7
        with:
          name: module
          path: |
            target/wasm32-unknown-unknown/release/*.wasm
            target/portaki/

  release:                    # the publishing rights: nothing of the module runs here
    needs: build
    runs-on: ubuntu-latest
    environment: release
    permissions: { contents: read, packages: write, id-token: write }
    steps:
      - uses: actions/checkout@v7
      - uses: actions/download-artifact@v8
        with: { name: module, path: target }
      - uses: PortakiApp/portaki-release-action@v1
        with: { build: false }
```

The `build` job audits the module's dependencies with `cargo audit`, builds it for `wasm32`,
lints its manifest, runs its tests and the conformity suite, and packages the OCI artifact —
without any right to publish. The `release` job pushes exactly that artifact
(`portaki publish --prebuilt`: no build, no tests, and the CLI refuses an artifact whose id or
version differs from the sources), signs it keylessly with its provenance and audit report,
announces the version to the registry, warns about anything ageing, and writes a row into the run
summary. The full file is [`examples/single-module.yml`](examples/single-module.yml).

### Why two jobs

A module's `build.rs` and its tests are code its author wrote. Run in a job that holds
`id-token: write` and `packages: write`, that code can request the job's OIDC token — the
identity the artifact is signed with — and push to the registry. The `release` job therefore runs
nothing of the module: it reads the sources (manifest, i18n, changelog) and pushes what `build`
produced.

`build: false` needs a CLI with `publish --prebuilt` (portaki-sdk 8.8.0 or later). With an older
one the action warns and keeps the previous behaviour, which runs the module's tests in that job.

A single job — `uses: PortakiApp/portaki-release-action@v1` with the default `build: true` —
still works, but is **discouraged: the module's code runs with the publishing rights**. The action
says so in a warning.

## What it does not do

**It does not orchestrate a monorepo.** A repository holding several modules builds its own
matrix: it knows its parallelism limits, its environments and its publication order better than
this action does. Deciding for the caller would lock them into one layout.

What this repository provides is tools — [`portaki ci modules`](https://github.com/PortakiApp/portaki-sdk)
answers *which modules*, and the action releases the one you name. See
[`examples/monorepo.yml`](examples/monorepo.yml) for the matrix shape.

## Actions

| Action | Role |
|--------|------|
| `PortakiApp/portaki-release-action@v1` | Release the module in `working-directory` |
| `PortakiApp/portaki-release-action/install@v1` | Install the Portaki CLI, and nothing else |
| `PortakiApp/portaki-release-action/audit@v1` | Run `cargo audit` on the module's `Cargo.lock` and write the report |
| `PortakiApp/portaki-release-action/sign@v1` | Sign a pushed artifact and attach its provenance and audit report |

`install` is separate because everything needs it first, and because a workflow often wants the
CLI on its own — to list modules, to inspect an artifact, to run `portaki ci check` in a job that
does not publish. `audit` and `sign` are separate for a repository that builds in one job and
publishes from another: the main action runs both itself.

## Inputs

| Input | Default | Meaning |
|-------|---------|---------|
| `working-directory` | `.` | The module — the directory holding its `portaki.module.json` |
| `channel` | `stable` | Registry channel the publication is announced on |
| `registry` | `ghcr.io/portakiapp` | OCI registry prefix |
| `api-url` | *(empty)* | Platform to announce to; empty means production |
| `cli-version` | `auto` | Exact CLI version, or the SDK version this checkout resolves to |
| `cache` | `false` | Cache the compiled CLI between runs — see [the cache](#the-cache) |
| `build` | `true` | `false`: push the artifact a job without rights built and tested, running nothing of the module (recommended). `true`: build, lint and test here — discouraged, the module's code runs with the publishing rights |
| `check` | `true` | Warn about an outdated SDK or a manifest the shell has moved past |
| `audit-fail-on` | `critical` | Lowest `cargo audit` severity that fails the release — see [the audit](#the-dependency-audit) |
| `dry-run` | `false` | Build, test and package without pushing or announcing — the `build` job of the two-job shape |
| `summary` | `true` | Append a row to the run summary |
| `report` | `true` | Tell Portaki how the run ended, so a broken module raises an alert and a fixed one clears it |

Outputs: `id`, `version`, `outcome` (`published`, `already-published`, `dry-run`), `digest` (the
digest signed and announced).

The run report runs on **every** outcome, not only failures: conditioned on failure it could
never *clear* an alert, and a module that has been fixed would keep its own indefinitely. It
needs `id-token: write`, stores nothing on your side, and a report that fails never fails the
job — the publication already happened.

## How the CLI version is chosen

`cli-version: auto` reads the **`Cargo.lock`** nearest the module, not its `Cargo.toml`: a module
may declare the SDK by semver, by git branch or by path, and only the lock says what will
actually compile.

The CLI is then installed at that version, in this order:

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

### The cache

The cache is keyed on that version alone, so it turns over when the SDK does. `install` saves it
right after `cargo install`, before the job runs anything of the module — a `build.rs` can no
longer swap the binary that ends up cached.

The release action does **not** use it by default (`cache: false`): its job holds the publishing
rights, and a cached binary is only as trustworthy as every job allowed to write the cache —
including one that ran module code on a runner it could tamper with. `install` keeps `cache:
true` for jobs that build, lint or list; pass `cache: false` to it too in a job that holds
secrets.

These actions are built on `portaki ci`, so they need a CLI that has it. When the resolved
version is older, the install step says so in one line rather than letting every later step fail
on `unrecognized subcommand` — raise the SDK your module resolves to, or pin `cli-version`.

> One step reads the lockfile in shell, because nothing is installed yet. It duplicates what
> `portaki ci sdk-version` does properly — so the step right after the install compares the two
> and warns if they disagree. The duplication is guarded by an assertion, not by trust.

## Signature and provenance

Portaki production runs a module only if its digest carries a valid signature from the workflow
linked to that module. An artifact pushed to GHCR by hand, outside CI, is never run there.

The publication therefore happens in three steps, all in the job that holds `id-token: write`:

1. `portaki publish --no-announce` pushes the artifact;
2. [cosign](https://github.com/sigstore/cosign) v3.1.3 signs its digest **without a key**: the
   job's OIDC token is exchanged at Sigstore's Fulcio for a short-lived certificate naming the
   repository, the commit, the workflow file and the ref, and every signature is recorded in the
   public Rekor log. Next to it, `cosign attest` attaches a
   [SLSA v1 provenance](https://slsa.dev/provenance/v1) and the `cargo audit` report
   (`https://portaki.app/attestations/cargo-audit/v1`);
3. `portaki publish --announce-only` announces the version. The registry verifies the signature
   against the repository and workflow of the module's link, and records the result (`signed`,
   `unsigned`, or refuses an `invalid` one).

Why cosign rather than GitHub's `actions/attest-build-provenance`: GitHub attestations are only
available to private repositories on GitHub Enterprise Cloud, and a community module may well
live in a private repository on a free plan. cosign keyless works for every repository, and the
same binary verifies on the registry side, so both ends read one format.

The signing identity is the **job**. A malicious `build.rs` or test running in that job could
request the same token — which is why the module is built and tested in a job without
`id-token`, and published with `build: false` (`portaki publish --prebuilt`) from another. A private repository
is named in the public Rekor log when it signs; that is the price of a verifiable signature.

Nothing to configure: the action installs cosign and signs. The job only needs the permissions
below.

## The dependency audit

Before building, the action runs [`cargo audit`](https://rustsec.org) (RustSec) on the
`Cargo.lock` nearest the module — a prebuilt, SHA-256-pinned `cargo-audit` binary, so nothing of
the module is compiled for it. The report lands in `target/portaki/cargo-audit.json` and is
attested with the artifact; the registry keeps its summary, shown to reviewers and to the author.

Severity comes from the advisory's CVSS 3.x vector: `critical` ≥ 9.0, `high` ≥ 7.0, `medium` ≥
4.0, `low` below. `audit-fail-on` (default `critical`) is the lowest severity that fails the
release. An advisory without a CVSS 3 vector is `unknown` and only warns. Informational
advisories — `unmaintained`, `unsound`, `notice`, `yanked` — never fail a release: an
unmaintained crate is a reason to look, not to block.

With `build: false`, the report comes from the job that built, with the artifact, under
`target/portaki/cargo-audit.json`. The action run there with `dry-run: true` writes it; a build
job of your own runs `audit@v1` before building:

```yaml
- uses: PortakiApp/portaki-release-action/audit@v1
  with:
    working-directory: modules/${{ matrix.module }}
```

## One publication at a time

Two jobs publishing the same module at once overwrite the same OCI tag in turn, and the
catalogue ends up referencing a digest the tag no longer carries. The CLI refuses to push a
version the registry already holds, which covers a re-run — but two jobs starting together both
look before either announces.

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
  packages: write     # l'artefact, et sa signature poussée à côté
  id-token: write     # sans quoi il n'y a pas de jeton OIDC à échanger, ni d'identité qui signe
```

No publication secret to store, no signing key. In a job with `id-token: write`, the CLI asks
GitHub for the job's OIDC token and exchanges it at the registry for a single-use publication
credential; cosign exchanges the same kind of token at Sigstore for its signing certificate. The
token proves where it comes from; the link registered in the dashboard decides what it may
publish — so link the module to its repository there before the first run.

The `stable` channel additionally requires the `environment:` declared in that link. Without it
the exchange is refused with `environment_required`.

## Examples

- [`examples/single-module.yml`](examples/single-module.yml) — one repository, one module, two jobs
- [`examples/monorepo.yml`](examples/monorepo.yml) — your matrix, our tools, the same two jobs

## License

[Apache-2.0](LICENSE) · Copyright 2026 Syntax Labs
