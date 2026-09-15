# Automata Debian Package Repository

[![CI](https://github.com/automataIA/debian-package-repository/actions/workflows/ci.yml/badge.svg)](https://github.com/automataIA/debian-package-repository/actions/workflows/ci.yml)

Build, test, release, and publish Debian packages for
[automataIA](https://github.com/automataIA) projects from one central repository.

This repository contains Debian packaging recipes, build automation, and the
configuration for a signed APT repository. Application source code remains in
its upstream repository, and generated `.deb` files are attached to upstream
GitHub Releases rather than committed here.

> [!IMPORTANT]
> **Publication status:** GitHub Pages is configured to deploy through GitHub
> Actions, but the first APT publication has not run yet. The public endpoint
> currently returns `404`, so the packages listed below are not installable
> through APT yet.

This is an independent third-party package repository. It is not part of or
endorsed by the Debian project.

## Packages

`Enabled` means that the central build and release scripts include the package.
It does not mean that the package is already available from the public APT
endpoint.

### Enabled packages

| Debian package | What it provides | Upstream source |
| --- | --- | --- |
| `search2md` | Searches the web and converts search results or web pages into clean Markdown. | [automataIA/search2md](https://github.com/automataIA/search2md) |
| `rag-bone-rs` | Local semantic search for documentation and multi-language codebases. | [automataIA/rag-bone-rs](https://github.com/automataIA/rag-bone-rs) |
| `rust-relations-explorer` | Builds and queries a knowledge graph of relationships in a Rust codebase. | [automataIA/rust-relations-explorer](https://github.com/automataIA/rust-relations-explorer) |
| `kan-bone-rs` | A COSMIC desktop Kanban application and companion panel applet. | [automataIA/kan-bone-rs](https://github.com/automataIA/kan-bone-rs) |
| `automata-archive-keyring` | Installs the repository signing key and Deb822 APT source configuration. | This repository |

### Recipes not yet enabled

| Debian package | What it provides | Upstream source |
| --- | --- | --- |
| `graphlib` | Offline GraphRAG document search combining embeddings with a knowledge graph. | [automataIA/graph-librarian-rs](https://github.com/automataIA/graph-librarian-rs) |
| `sir-bone-rs` | A Rust coding agent with LLM streaming, tools, REPL, TUI, and MCP support. | [automataIA/sir-bone-rs](https://github.com/automataIA/sir-bone-rs) |

Additional candidates are tracked in
[`config/packages.toml`](config/packages.toml), but they do not have an active
packaging workflow yet.

## Supported systems

Published packages target:

- Debian 12 (Bookworm) and newer;
- Ubuntu 22.04 and newer, including Pop!_OS 24.04;
- `amd64` systems.

Release artifacts are built in the pinned Debian Bookworm container. This keeps
the glibc requirement compatible with the oldest supported distributions. The
repository uses one rolling `stable` suite and the `main` component.

## How the repository works

```text
upstream source repository
          |
          | copied into an isolated build tree
          v
packages/<name>/debian + package.toml
          |
          | dpkg-buildpackage in Debian Bookworm
          v
.work/artifacts/*.deb
          |
          | scripts/release
          v
upstream GitHub Release
          |
          | publish-apt.yml + reprepro
          v
signed APT repository on GitHub Pages
```

The source checkout is mounted read-only during container builds. The scripts
copy it into `.work/`, add the matching Debian recipe, generate the changelog,
build the package, run package checks, and preserve the resulting `.deb`,
`.buildinfo`, `.changes`, and source tarball.

The publication workflow rebuilds the APT repository from all enabled GitHub
Release assets. It accepts only declared package names and architectures,
selects the highest version using Debian version semantics, signs the repository
metadata, tests installation in containers, and deploys the result to GitHub
Pages.

## Installation

The commands in this section will work **after the first APT publication**.
Until the deployment notice at the top of this README is removed, use source
builds from the individual upstream projects instead.

The preferred setup method is the `automata-archive-keyring` package. It places
the package-managed key in `/usr/share/keyrings/` and installs a Deb822
`.sources` file that restricts trust to this repository with `Signed-By`.

```bash
wget https://automataia.github.io/debian-package-repository/pool/main/a/automata-archive-keyring/automata-archive-keyring_1.0.0-1_all.deb
sudo apt install ./automata-archive-keyring_*_all.deb
sudo apt update
sudo apt install search2md
```

Before installing the bootstrap package for the first time, verify its checksum
and the repository key fingerprint through an independent trusted channel:

```text
4034 08F5 E286 FDE9 CBD1 A6E2 CF4A F8E0 A5A5 35B6
```

After configuration, inspect the source and candidate version with:

```bash
cat /etc/apt/sources.list.d/automata.sources
apt-cache policy search2md
```

## Build packages locally

### Prerequisites

- Docker with access to a running daemon;
- Git;
- local upstream checkouts at the paths declared in
  [`config/packages.toml`](config/packages.toml).

The container provides the packaging and Rust build tools. A local Rust
toolchain is required only when using `./scripts/build` without Docker.

Build one package in the supported Bookworm environment:

```bash
./scripts/build-in-docker search2md
```

Build every enabled package:

```bash
./scripts/build-in-docker --all
```

Artifacts are written to `.work/artifacts/`. A native host build is useful for
development, but should not be published because it inherits the host system's
glibc floor:

```bash
./scripts/build search2md
```

Run the repository checks:

```bash
./scripts/selftest
./scripts/repo-test --structure-only
```

For a complete local APT test, first build the repository from local artifacts,
then install every indexed package in the supported distribution matrix:

```bash
./scripts/keygen                  # one-time setup, if no signing key exists
./scripts/repo-build --local
./scripts/repo-test
./scripts/repo-test-docker
```

## Release a package

Package releases require a clean upstream checkout whose exact `HEAD` commit is
already available on its `origin` remote.

Preview the operation:

```bash
./scripts/release search2md --dry-run
```

Build, publish, and trigger the central APT workflow:

```bash
./scripts/release search2md
```

The release tag follows `<package>-v<upstream-version>-<debian-revision>`, for
example `search2md-v0.1.0-1`.

## Add a package

1. Add `packages/<name>/package.toml` with package metadata, expected binaries,
   and a smoke-test command.
2. Add the Debian recipe under `packages/<name>/debian/`.
3. Register the package in [`config/packages.toml`](config/packages.toml).
4. Build it with `./scripts/build-in-docker <name>`.
5. Run `./scripts/repo-test --structure-only`.
6. Inspect the package with `lintian` and test it in the supported container
   matrix before setting `enabled = true`.

Recipes use debhelper compatibility level 13, `Rules-Requires-Root: no`, locked
Cargo dependencies, a machine-readable copyright file, and package-specific
smoke tests. Multi-binary recipes must declare every generated Debian package so
the publication boundary can reject unexpected artifacts.

## Repository layout

| Path | Purpose |
| --- | --- |
| [`config/packages.toml`](config/packages.toml) | Package registry, upstream locations, GitHub repositories, and enabled state. |
| [`config/repository.toml`](config/repository.toml) | APT suite, architecture, maintainer, signing identity, and Pages URL. |
| [`packages/`](packages/) | Package metadata and Debian recipes. |
| [`scripts/`](scripts/) | Build, validation, release, signing, and repository-generation commands. |
| [`docker/`](docker/) | Pinned Debian Bookworm build environment. |
| [`repo/conf/`](repo/conf/) | `reprepro` configuration. |
| [`keyrings/`](keyrings/) | Public repository key only. Private key material must never be committed. |
| [`.github/workflows/`](.github/workflows/) | Static CI checks and signed APT publication. |
| `.work/`, `public/` | Generated local build state and Pages output; both are ignored by Git. |

Maintainer working notes are deliberately kept outside the public Git history.
Durable user-facing and contributor-facing documentation belongs in this
README or in a reviewed public document added explicitly for that purpose.

## Security and packaging practices

- A dedicated OpenPGP key signs the APT `InRelease` metadata.
- APT trust is scoped with `Signed-By`; the deprecated `apt-key` workflow is not
  used.
- The package-managed public key lives in `/usr/share/keyrings/`.
- The private signing key stays outside Git and is imported into an isolated CI
  keyring from GitHub Actions secrets.
- The workflow verifies the imported key fingerprint before signing.
- Release assets are bound to their declared upstream repository, package name,
  and architecture before inclusion.
- Signed metadata expires after 14 days and is refreshed by a weekly workflow.
- Builds preserve `.buildinfo`, `.changes`, checksums, and deterministic source
  metadata for auditability.
- CI pins third-party GitHub Actions by full commit SHA.

These choices follow current APT guidance for
[Deb822 sources](https://manpages.debian.org/stable/apt/sources.list.5.en.html)
and
[repository authentication](https://manpages.debian.org/stable/apt/apt-secure.8.en.html).

## Current limitations

- The public APT endpoint still needs its first deployment.
- Only `amd64` packages are built.
- This is a binary-oriented third-party repository, not a Debian archive with
  independently rebuildable source packages.
- Cargo dependencies are locked, but network package sources and APT packages
  are not pinned to immutable snapshots; builds are not yet bit-for-bit
  reproducible.
- The single rolling `stable` suite is intended for standalone applications.
  Distribution-specific suites may be required if packages gain incompatible
  system dependencies.

## License

The repository tooling and packaging files are available under the terms in
[`LICENSE`](LICENSE). Each packaged project retains its own upstream license.
