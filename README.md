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
- uses: PortakiApp/portaki-release-action@v1
```

That builds the module in the current directory for `wasm32`, lints its manifest, pushes the OCI
artifact, announces the version to the registry, warns about anything ageing, and writes a row
into the run summary.

## What it does not do

**It does not orchestrate a monorepo.** A repository holding several modules builds its own
matrix: it knows its parallelism limits, its environments and its publication order better than
this action does. Deciding for the caller would lock them into one layout.

What this repository provides is tools — [`portaki ci modules`](https://github.com/PortakiApp/portaki-sdk)
answers *which modules*, and the action releases the one you name. See
[`examples/monorepo.yml`](examples/monorepo.yml) for the two-job shape.

## Actions

| Action | Role |
|--------|------|
| `PortakiApp/portaki-release-action@v1` | Release the module in `working-directory` |
| `PortakiApp/portaki-release-action/install@v1` | Install the Portaki CLI, and nothing else |

`install` is separate because everything needs it first, and because a workflow often wants the
CLI on its own — to list modules, to inspect an artifact, to run `portaki ci check` in a job that
does not publish.

## Inputs

| Input | Default | Meaning |
|-------|---------|---------|
| `working-directory` | `.` | The module — the directory holding its `portaki.module.json` |
| `channel` | `stable` | Registry channel the publication is announced on |
| `registry` | `ghcr.io/portakiapp` | OCI registry prefix |
| `api-url` | *(empty)* | Platform to announce to; empty means production |
| `cli-version` | `auto` | Exact CLI version, or the SDK version this checkout resolves to |
| `cache` | `false` | Cache the compiled CLI between runs — see [the cache](#the-cache) |
| `build` | `true` | Build and lint first; `false` publishes an artifact a previous job produced |
| `check` | `true` | Warn about an outdated SDK or a manifest the shell has moved past |
| `dry-run` | `false` | Build and package without pushing or announcing |
| `summary` | `true` | Append a row to the run summary |
| `report` | `true` | Tell Portaki how the run ended, so a broken module raises an alert and a fixed one clears it |

Outputs: `id`, `version`, `outcome` (`published`, `already-published`, `dry-run`).

The run report runs on **every** outcome, not only failures: conditioned on failure it could
never *clear* an alert, and a module that has been fixed would keep its own indefinitely. It
needs `id-token: write`, stores nothing on your side, and a report that fails never fails the
job — the publication already happened.

## How the CLI version is chosen

`cli-version: auto` reads the **`Cargo.lock`** nearest the module, not its `Cargo.toml`: a module
may declare the SDK by semver, by git branch or by path, and only the lock says what will
actually compile.

The CLI is then installed **from crates.io** at that version — `cargo install portaki-cli@2.2.0`.
Cloning the SDK repository to build it there would cost a branch resolution on every run, a
cache invalidated by every commit to that branch, and a binary matching no published release.

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

```yaml
permissions:
  contents: read
  packages: write
  id-token: write     # sans quoi il n'y a pas de jeton OIDC à échanger
```

No publication secret to store. In a job with `id-token: write`, the CLI asks GitHub for the
job's OIDC token and exchanges it at the registry for a single-use publication credential. The
token proves where it comes from; the link registered in the dashboard decides what it may
publish — so link the module to its repository there before the first run.

The `stable` channel additionally requires the `environment:` declared in that link. Without it
the exchange is refused with `environment_required`.

## Examples

- [`examples/single-module.yml`](examples/single-module.yml) — one repository, one module
- [`examples/monorepo.yml`](examples/monorepo.yml) — your matrix, our tools

## License

[Apache-2.0](LICENSE) · Copyright 2026 Syntax Labs
