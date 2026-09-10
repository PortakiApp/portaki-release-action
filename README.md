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
| `cache` | `true` | Cache the compiled CLI between runs |
| `check` | `true` | Warn about an outdated SDK or a manifest the shell has moved past |
| `dry-run` | `false` | Build and package without pushing or announcing |
| `summary` | `true` | Append a row to the run summary |

Outputs: `id`, `version`, `outcome` (`published`, `already-published`, `dry-run`).

## How the CLI version is chosen

`cli-version: auto` reads the **`Cargo.lock`** nearest the module, not its `Cargo.toml`: a module
may declare the SDK by semver, by git branch or by path, and only the lock says what will
actually compile.

The CLI is then installed **from crates.io** at that version — `cargo install portaki-cli@2.2.0`.
Cloning the SDK repository to build it there would cost a branch resolution on every run, a
cache invalidated by every commit to that branch, and a binary matching no published release.

The cache is keyed on that version alone, so it turns over when the SDK does. `cache: false`
disables it where a stale binary would be worse than a rebuild.

> One step reads the lockfile in shell, because nothing is installed yet. It duplicates what
> `portaki ci sdk-version` does properly — so the step right after the install compares the two
> and warns if they disagree. The duplication is guarded by an assertion, not by trust.

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
