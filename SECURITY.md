# Security policy

## Reporting a vulnerability

Report security issues privately through
[GitHub private vulnerability reporting](https://github.com/automataIA/debian-package-repository/security/advisories/new).
Do not open a public issue containing credentials, private keys, personal data,
or exploit details for an unpatched vulnerability.

Include the affected package or script, version, impact, reproduction steps,
and any suggested mitigation. Never include a real secret in a reproduction;
use an obviously invalid placeholder.

## Scope

This repository contains Debian packaging recipes, repository-generation
scripts, a public APT signing key, and GitHub Actions workflows. Application
source code is maintained in the upstream repositories linked from
[README.md](README.md). Report application vulnerabilities to the corresponding
upstream project unless the issue is caused by packaging or publication here.

## Secret handling

- Only the public APT key may be committed under `keyrings/`.
- The private APT signing key and passphrase belong in GitHub Actions secrets
  or an isolated local GnuPG home, never in Git.
- Maintainer working notes belong outside this public repository.
- Generated packages and repository output belong in the ignored build
  directories, not in Git history.
- If a credential is exposed, revoke or rotate it immediately. Removing it
  from Git history does not make the old value safe.
