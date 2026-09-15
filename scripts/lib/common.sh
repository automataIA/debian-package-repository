#!/usr/bin/env bash
# shellcheck disable=SC2034  # shared library: globals consumed by callers
# common.sh — shared library for the automata debian-package-repository
# scripts. Sourced, never executed directly.
#
# Depends on: bash, python3 (stdlib tomllib), rsync, git, dpkg tools.
# Missing packaging tools (debhelper, reprepro, lintian) are bootstrapped
# rootless into .work/tools by scripts/bootstrap-tools when needed.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config"
PACKAGES_DIR="$REPO_ROOT/packages"
WORK_DIR="$REPO_ROOT/.work"
ARTIFACTS_DIR="$WORK_DIR/artifacts"
INCOMING_DIR="$WORK_DIR/incoming"
REPO_DIR="$REPO_ROOT/repo"
PUBLIC_DIR="$REPO_ROOT/public"
TEMPLATES_DIR="$REPO_ROOT/templates"
# Bootstrapped tools are ABI-bound to the distribution that produced them
# (the Perl modules of a noble lintian abort under a bookworm perl), so a
# container build points this at its own directory via APT_TOOLS_DIR.
TOOLS_DIR="${APT_TOOLS_DIR:-$WORK_DIR/tools}"
KEYRINGS_DIR="$REPO_ROOT/keyrings"

# ---------------------------------------------------------------- logging ---

if [ -t 2 ]; then
    C_INFO=$'\033[1;34m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'; C_OFF=$'\033[0m'
else
    C_INFO=""; C_WARN=""; C_ERR=""; C_OFF=""
fi

log()  { printf '%s==>%s %s\n'  "$C_INFO" "$C_OFF" "$*"; }
step() { printf '    %s\n' "$*"; }
warn() { printf '%sWARN%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%sERROR%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

usage() {
    # print the whole leading comment block, however long it is
    awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
    exit "${1:-0}"
}

# ------------------------------------------------------------ toml access ---

# toml_get <file> <dotted.key>  — returns the raw TOML value (string/number).
# Arrays are printed one element per line. Missing key prints nothing and
# returns 1.
toml_get() {
    python3 - "$1" "$2" <<'PY'
import sys, tomllib
path, key = sys.argv[1], sys.argv[2].split(".")
with open(path, "rb") as f:
    data = tomllib.load(f)
for k in key:
    if not isinstance(data, dict) or k not in data:
        sys.exit(1)
    data = data[k]
if isinstance(data, list):
    print("\n".join(str(i) for i in data))
elif isinstance(data, bool):
    print("true" if data else "false")
elif data is not None:
    print(data)
PY
}

# toml_keys <file> <table.dotted>  — prints the keys of a TOML table.
toml_keys() {
    python3 - "$1" "$2" <<'PY'
import sys, tomllib
path, key = sys.argv[1], sys.argv[2]
with open(path, "rb") as f:
    data = tomllib.load(f)
if key:
    for k in key.split("."):
        if not isinstance(data, dict) or k not in data:
            sys.exit(0)
        data = data[k]
if isinstance(data, dict):
    print("\n".join(data.keys()))
PY
}

# ------------------------------------------------------------ repo config ---

REPO_ORIGIN="" REPO_LABEL="" REPO_CODENAME="" REPO_SUITE=""
REPO_ARCHS="" REPO_COMPONENTS="" REPO_DESCRIPTION=""
REPO_MAINTAINER="" REPO_DEBCOMPAT="" REPO_STANDARDS=""
GH_OWNER="" GH_REPO="" PAGES_URL=""
KEYRING_PACKAGE="" KEYRING_PUBLIC_FILE="" GNUPG_HOME="" SIGNING_FPR=""

load_repo_config() {
    local f="$CONFIG_DIR/repository.toml"
    [ -f "$f" ] || die "missing $f"
    REPO_ORIGIN="$(toml_get "$f" repository.origin)"
    REPO_LABEL="$(toml_get "$f" repository.label)"
    REPO_CODENAME="$(toml_get "$f" repository.codename)"
    REPO_SUITE="$(toml_get "$f" repository.suite)"
    REPO_ARCHS="$(toml_get "$f" repository.architectures | tr '\n' ' ' | sed 's/ $//')"
    REPO_COMPONENTS="$(toml_get "$f" repository.components | tr '\n' ' ' | sed 's/ $//')"
    REPO_DESCRIPTION="$(toml_get "$f" repository.description)"
    REPO_MAINTAINER="$(toml_get "$f" repository.maintainer)"
    REPO_DEBCOMPAT="$(toml_get "$f" repository.debhelper_compat)"
    REPO_STANDARDS="$(toml_get "$f" repository.standards_version)"
    GH_OWNER="$(toml_get "$f" github.owner)"
    GH_REPO="$(toml_get "$f" github.repo)"
    PAGES_URL="$(toml_get "$f" github.pages_url)"
    KEYRING_PACKAGE="$(toml_get "$f" keyring.package)"
    KEYRING_PUBLIC_FILE="$(toml_get "$f" keyring.public_key_file)"
    GNUPG_HOME="$(toml_get "$f" keyring.gnupg_home)"
    SIGNING_FPR="$(toml_get "$f" keyring.signing_key_fingerprint)"
    GNUPG_HOME="${APT_GNUPGHOME:-$(expand_path "$GNUPG_HOME")}"
    [ -n "$REPO_CODENAME" ] || die "repository.codename not set in $f"
}

# ----------------------------------------------------------- package data ---

PKG_NAME="" PKG_SOURCE="" PKG_RECIPE_DIR="" PKG_GITHUB="" PKG_ENABLED=""
PKG_VERSION_SOURCE="" PKG_VERSION="" PKG_DEB_REVISION="" PKG_ARCH=""
PKG_SECTION="" PKG_PRIORITY="" PKG_DESCRIPTION="" PKG_LONG_DESCRIPTION=""
PKG_CARGO_PACKAGE="" PKG_CARGO_BINS="" PKG_CARGO_BUILD_FLAGS="" PKG_SMOKE_COMMAND=""

expand_path() {
    local p="$1"
    # the quoted tilde in the match patterns is intentional (literal "~")
    # shellcheck disable=SC2088
    case "$p" in
        "~") echo "$HOME";;
        "~/"*) echo "$HOME/${p#\~/}";;
        .) echo "$REPO_ROOT";;
        ./*) echo "$REPO_ROOT/${p#./}";;
        *) echo "$p";;
    esac
}

# load_package <name>  — reads packages/<name>/package.toml into PKG_*
# (packaging metadata only; the enabled flag and the GitHub repository
# come from the central registry in config/packages.toml — one authority
# per fact).
load_package() {
    local name="$1"
    load_registry_entry "$name"
    [ -n "$REG_RECIPE" ] || die "package '$name' has no recipe in config/packages.toml"
    PKG_RECIPE_DIR="$REG_RECIPE_DIR"
    local f="$PKG_RECIPE_DIR/package.toml"
    [ -f "$f" ] || die "unknown package '$name': $f not found"
    PKG_NAME="${name}"
    PKG_SOURCE="$REG_PATH"
    [ -n "$PKG_SOURCE" ] || PKG_SOURCE="$(expand_path "$(toml_get "$f" source)")"
    PKG_GITHUB="$REG_GITHUB"
    if [ -z "$PKG_GITHUB" ]; then
        PKG_GITHUB="$(toml_get "$f" github || true)"
    fi
    PKG_ENABLED="$(package_enabled "$name" && echo true || echo false)"
    PKG_VERSION_SOURCE="$(toml_get "$f" version_source || echo cargo)"
    PKG_VERSION="$(toml_get "$f" version || true)"
    PKG_DEB_REVISION="$(toml_get "$f" deb_revision || echo 1)"
    PKG_ARCH="$(toml_get "$f" architecture || echo auto)"
    [ "$PKG_ARCH" = "auto" ] && PKG_ARCH="$(dpkg --print-architecture)"
    PKG_SECTION="$(toml_get "$f" section || echo utils)"
    PKG_PRIORITY="$(toml_get "$f" priority || echo optional)"
    PKG_DESCRIPTION="$(toml_get "$f" description || true)"
    PKG_LONG_DESCRIPTION="$(python3 - "$f" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    d = tomllib.load(fh)
v = d.get("long_description", "")
print(v if isinstance(v, str) else "")
PY
)"
    PKG_CARGO_PACKAGE="$(toml_get "$f" cargo_package || true)"
    PKG_CARGO_BINS="$(toml_get "$f" cargo_bins || true)"
    PKG_CARGO_BUILD_FLAGS="$(toml_get "$f" cargo_build_flags || true)"
    PKG_SMOKE_COMMAND="$(toml_get "$f" smoke_command || true)"
    [ -d "$PKG_SOURCE" ] || die "source directory for '$name' not found: $PKG_SOURCE"
}

# list_enabled_packages — names from config/packages.toml (enabled ones first)
list_packages() {
    toml_keys "$CONFIG_DIR/packages.toml" packages
}

# registry_get <name> <key> — read a field of config/packages.toml only.
registry_get() {
    toml_get "$CONFIG_DIR/packages.toml" "packages.$1.$2"
}

package_enabled() {
    local name="$1"
    [ "$(toml_get "$CONFIG_DIR/packages.toml" "packages.$name.enabled" || echo true)" = "true" ]
}

# Registry-only entry loader: never touches recipes or local sources, so it
# is safe on a clean CI runner. Sets REG_* variables; empty string means
# "field not present in the registry".
REG_NAME="" REG_GITHUB="" REG_ENABLED="" REG_PATH="" REG_RECIPE="" REG_RECIPE_DIR="" REG_DEB_NAME=""
REG_DEB_NAMES=""
load_registry_entry() {
    local name="$1"
    REG_NAME="$name"
    REG_GITHUB="$(registry_get "$name" github || true)"
    REG_ENABLED="$(package_enabled "$name" && echo true || echo false)"
    REG_PATH="$(expand_path "$(registry_get "$name" path || true)")"
    REG_RECIPE="$(registry_get "$name" recipe || true)"
    REG_RECIPE_DIR=""
    if [ -n "$REG_RECIPE" ]; then
        case "$REG_RECIPE" in
            /*|.|..|../*|*/../*|*/..) die "$name: recipe must be relative to packages/ and may not contain '..': $REG_RECIPE";;
        esac
        REG_RECIPE_DIR="$PACKAGES_DIR/$REG_RECIPE"
    fi
    # expected Debian package name for release-asset validation; defaults
    # to the recipe name (entries without a recipe must set it explicitly)
    REG_DEB_NAME="$(registry_get "$name" deb_name || true)"
    if [ -z "$REG_DEB_NAME" ] && [ -n "$REG_RECIPE_DIR" ] && [ -f "$REG_RECIPE_DIR/package.toml" ]; then
        REG_DEB_NAME="$(toml_get "$REG_RECIPE_DIR/package.toml" name || true)"
    fi
    [ -n "$REG_DEB_NAME" ] || REG_DEB_NAME="$name"
    # A single debian/control may declare several binary packages. The
    # registry has to know all of them: scripts/build refuses a recipe that
    # produces an undeclared name, and repo-build rejects it as outside the
    # trust boundary. One name per line; defaults to the single deb_name.
    REG_DEB_NAMES="$(registry_get "$name" deb_names || true)"
    [ -n "$REG_DEB_NAMES" ] || REG_DEB_NAMES="$REG_DEB_NAME"
}

# source_commit_epoch <dir> — commit timestamp of the source tree, for
# deterministic changelogs and tarballs. Falls back to current time for
# non-git trees.
source_commit_epoch() {
    local dir="$1" epoch=""
    if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        epoch="$(git -C "$dir" log -1 --format=%ct 2>/dev/null || true)"
    fi
    echo "${epoch:-$(date +%s)}"
}

# --------------------------------------------------------------- versions ---

# upstream_version <source_dir> <version_source>
#   cargo           → [package].version of <dir>/Cargo.toml
#   cargo-workspace → [workspace.package].version of <dir>/Cargo.toml
#                     (virtual manifests: the members inherit it)
#   cargo:<path>    → version of Cargo.toml at <path> relative to <dir>
#   python          → [project].version of <dir>/pyproject.toml
#   static          → version key of packages/<name>/package.toml
upstream_version() {
    local dir="$1" vsrc="$2"
    case "$vsrc" in
        cargo)
            _toml_section_version "$dir/Cargo.toml" package ||
                die "cannot read version from $dir/Cargo.toml"
            ;;
        cargo-workspace)
            toml_get "$dir/Cargo.toml" workspace.package.version ||
                die "cannot read workspace.package.version from $dir/Cargo.toml"
            ;;
        python)
            _toml_section_version "$dir/pyproject.toml" project ||
                die "cannot read version from $dir/pyproject.toml"
            ;;
        static)
            [ -n "$PKG_VERSION" ] || die "version_source = static but no version set for $PKG_NAME"
            echo "$PKG_VERSION"
            ;;
        *)
            die "unsupported version_source '$vsrc' for $PKG_NAME"
            ;;
    esac
}

# Extract the "version" key from one specific section of a TOML file using
# section-aware awk (tomllib is preferred at runtime; this is the fallback
# used inside build trees where the top-level Cargo.toml is enough).
_toml_section_version() {
    local file="$1" section="$2"
    [ -f "$file" ] || return 1
    python3 - "$file" "$section" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    d = tomllib.load(f)
v = d.get(sys.argv[2], {}).get("version")
if v:
    print(v)
sys.exit(0 if v else 1)
PY
}

# ------------------------------------------------------------- git checks ---

git_head_or_dirty() {
    # prints "<sha>" for a clean tree, "<sha>-dirty" otherwise, "none" if
    # the directory is not a git work tree
    local dir="$1"
    if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "none"; return 0
    fi
    local sha
    sha="$(git -C "$dir" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
    if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
        echo "$sha-dirty"
    else
        echo "$sha"
    fi
}

assert_git_clean() {
    local dir="$1" allow_dirty="$2"
    [ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null || echo false)" = "true" ] || return 0
    if [ -n "$(git -C "$dir" status --porcelain)" ]; then
        if [ "$allow_dirty" = "true" ]; then
            warn "building '$dir' with uncommitted changes (--allow-dirty)"
        else
            die "'$dir' has uncommitted changes. Commit them or pass --allow-dirty."
        fi
    fi
}

# ----------------------------------------------------------------- tools ---

# activate_tools — prefer .work/tools (rootless bootstrap) over system PATH
activate_tools() {
    if [ -d "$TOOLS_DIR/usr/bin" ]; then
        PATH="$TOOLS_DIR/usr/bin:$PATH"
        export PATH
        if [ -d "$TOOLS_DIR/usr/share/perl5" ]; then
            PERL5LIB="${PERL5LIB:+$PERL5LIB:}$TOOLS_DIR/usr/share/perl5"
            export PERL5LIB
        fi
        # XS modules (Syntax::Keyword::Try and friends, needed by lintian)
        # are architecture-dependent and land under usr/lib, not usr/share
        local archdir
        for archdir in "$TOOLS_DIR"/usr/lib/*/perl5/*; do
            [ -d "$archdir" ] || continue
            PERL5LIB="${PERL5LIB:+$PERL5LIB:}$archdir"
            export PERL5LIB
        done
    fi
}

have() { command -v "$1" >/dev/null 2>&1; }

require_debhelper() {
    activate_tools
    have dh || die "debhelper not found. Run scripts/bootstrap-tools (no root needed) or: sudo apt install debhelper"
}

# check_desktop_files <deb> — validate the desktop entries and AppStream
# metainfo a package ships. ${shlibs:Depends} and lintian do not catch a
# malformed .desktop, and a desktop file the launcher refuses makes the
# application invisible while the package looks perfectly installed.
check_desktop_files() {
    local deb="$1" tmp rc=0
    tmp="$(mktemp -d "$WORK_DIR/deskcheck.XXXXXX")"
    dpkg-deb -x "$deb" "$tmp"

    local f found=false
    for f in "$tmp"/usr/share/applications/*.desktop; do
        [ -e "$f" ] || break
        found=true
        if have desktop-file-validate; then
            desktop-file-validate "$f" || { warn "invalid desktop entry: $(basename "$f")"; rc=1; }
        else
            warn "desktop-file-validate not available — $(basename "$f") unchecked (scripts/bootstrap-tools desktop-file-utils)"
        fi
    done
    for f in "$tmp"/usr/share/metainfo/*.xml; do
        [ -e "$f" ] || break
        found=true
        if have appstreamcli; then
            # appstreamcli exits non-zero on warnings and infos too; only an
            # E: tag means the metadata is actually unusable, so mirror the
            # lintian policy and fail the build on errors alone.
            local out
            out="$(appstreamcli validate --no-net "$f" 2>&1 || true)"
            if printf '%s\n' "$out" | grep -q '^E:'; then
                printf '%s\n' "$out" >&2
                warn "AppStream metainfo has errors: $(basename "$f")"
                rc=1
            elif printf '%s\n' "$out" | grep -q '^W:'; then
                printf '%s\n' "$out" >&2
            fi
        else
            warn "appstreamcli not available — $(basename "$f") unchecked (apt install appstream)"
        fi
    done
    [ "$found" = true ] && step "desktop/AppStream files checked"
    rm -rf "$tmp"
    [ "$rc" = 0 ] || die "$(basename "$deb"): desktop/AppStream validation failed"
}

# run_lintian <deb> — mandatory. A skipped lintian is how a packaging
# mistake reaches the signed repository unnoticed, so a missing lintian is
# an error rather than a warning; scripts/bootstrap-tools installs it
# without root. Set LINTIAN=off to bypass it deliberately.
run_lintian() {
    local deb="$1"
    if [ "${LINTIAN:-}" = "off" ]; then
        warn "lintian disabled via LINTIAN=off — $(basename "$deb") unchecked"
        return 0
    fi
    activate_tools
    have lintian || die "lintian not found — run scripts/bootstrap-tools lintian (no root needed), or set LINTIAN=off to bypass"
    step "running lintian on $(basename "$deb")"
    # ONE run, status captured on its own: piping lintian into grep would
    # hide the verdict, because under `set -o pipefail` lintian's own
    # non-zero exit (exactly what an error tag produces) becomes the
    # pipeline status and the `if` reads it as "no match".
    # Exit status (lintian(1)): 0 clean, 1 lintian itself failed,
    # 2 a --fail-on condition was met. Tags are advisory here (private
    # binary recipes, not archive uploads) except errors.
    local out status=0
    out="$(lintian --info --display-info --fail-on error "$deb" 2>&1)" || status=$?
    printf '%s\n' "$out"
    case "$status" in
        0) ;;
        2) die "$(basename "$deb"): lintian reported errors (above)";;
        *) die "$(basename "$deb"): lintian failed to run (exit $status) — the package is unchecked";;
    esac
}

require_reprepro() {
    activate_tools
    have reprepro || die "reprepro not found. Run scripts/bootstrap-tools (no root needed) or: sudo apt install reprepro"
}

# -------------------------------------------------------------- changelog ---

write_debian_changelog() {
    # $1 = destination debian dir, $2 = package name,
    # $3 = full debian version (e.g. 0.4.2-1), $4 = provenance note,
    # $5 = SOURCE_DATE_EPOCH (optional; deterministically fixes the date)
    local debsrc="$1" name="$2" fullver="$3" note="$4" epoch="${5:-}"
    local when
    if [ -n "$epoch" ]; then
        when="$(date -u -d "@$epoch" -R)"
    else
        when="$(date -R)"
    fi
    cat > "$debsrc/changelog" <<EOF
$name ($fullver) $REPO_SUITE; urgency=medium

  * $note

 -- $REPO_MAINTAINER  $when
EOF
}

# ---------------------------------------------------------------- render ---

render_template() {
    # render_template <template> <destination>  — substitutes @TOKEN@ with
    # values read from stdin as "TOKEN=value" lines (values may contain any
    # character except newline). The Python program is passed via -c so the
    # process stdin stays available for the token data.
    local tpl="$1" dst="$2"
    python3 -c '
import pathlib, sys
tokens = {}
for line in sys.stdin.read().splitlines():
    if not line:
        continue
    key, _, value = line.partition("=")
    tokens[f"@{key}@"] = value
src = pathlib.Path(sys.argv[1]).read_text()
for k, v in tokens.items():
    src = src.replace(k, v)
pathlib.Path(sys.argv[2]).write_text(src)
' "$tpl" "$dst"
}

render_repo_tokens() {
    # prints the standard repository token set for render_template
    printf 'ORIGIN=%s\n' "$REPO_ORIGIN"
    printf 'LABEL=%s\n' "$REPO_LABEL"
    printf 'CODENAME=%s\n' "$REPO_CODENAME"
    printf 'SUITE=%s\n' "$REPO_SUITE"
    printf 'ARCHS=%s\n' "$REPO_ARCHS"
    printf 'COMPONENTS=%s\n' "$REPO_COMPONENTS"
    printf 'DESCRIPTION=%s\n' "$REPO_DESCRIPTION"
    printf 'MAINTAINER=%s\n' "$REPO_MAINTAINER"
    printf 'GH_OWNER=%s\n' "$GH_OWNER"
    printf 'GH_REPO=%s\n' "$GH_REPO"
    printf 'PAGES_URL=%s\n' "$PAGES_URL"
    printf 'KEYRING_PACKAGE=%s\n' "$KEYRING_PACKAGE"
    printf 'KEYRING_FILE=%s\n' "$KEYRING_PUBLIC_FILE"
    printf 'KEYRING_FPR=%s\n' "$SIGNING_FPR"
}

deb_full_version() {
    echo "$(upstream_version "$PKG_SOURCE" "$PKG_VERSION_SOURCE")-$PKG_DEB_REVISION"
}
