#!/usr/bin/env bash
# build.sh — universal Arch package builder for PdLinuXOS
# Rebuilds full repo database each run (scans all *.pkg.tar.* in repo dir).
# Copies built packages to local binary repo, repo-add over all packages,
# optional git commit+push with either credential helper or PAT read from file.
# Inline comments in English by design.

set -euo pipefail

### ========= Config (edit these defaults as you like) =========

REPO_NAME="pdlx"                             # repo db prefix -> pdlx.db.tar.xz
LOCAL_REPO_DIR="/home/ali/pdlx/x86_64"       # your default binary repo dir

REMOTE_GIT_URL="https://github.com/PersianBSD/pdlx.git"        # optional; if LOCAL_REPO_DIR already has origin, leave empty
GIT_BRANCH="main"

# Token handling:
USE_GITHUB_PAT=true       # set true to inject PAT into remote url on push
GITHUB_USER="persianbsd"   # placeholder, replace with your GitHub username
# Prefer reading token from file or env, not hardcoding:
GITHUB_TOKEN_FILE="${HOME}/.config/pdlx/github_token"  # chmod 600
# If env GITHUB_TOKEN is set, it overrides file
# If neither set and USE_GITHUB_PAT=true, push will fail with a clear error

MAKEPKG_FLAGS=(-s --noconfirm)  # add --cleanbuild if you want pristine builds
### ======================================

_die(){ echo "ERROR: $*" >&2; exit 1; }
_info(){ echo -e "\e[1;34m==>\e[0m $*"; }
_have(){ command -v "$1" >/dev/null 2>&1; }

### ========= CLI =========
# --no-updpkgsums   Skip updpkgsums
# --install         pacman -U after build
# --repo <dir>      override repo dir
# --repo-name <n>   override db name
# --push            commit+push repo dir
# --remote <url>    override REMOTE_GIT_URL
# --branch <name>   override GIT_BRANCH
# --clean           rm src/pkg/old artifacts before build
# --sign            repo-add -s (requires GPG)
# --quiet           makepkg --quiet

RUN_UPDPKGSUMS=true
DO_INSTALL=false
DO_PUSH=false
DO_CLEAN=false
SIGN_DB=false
QUIET=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-updpkgsums) RUN_UPDPKGSUMS=false; shift ;;
    --install)       DO_INSTALL=true; shift ;;
    --repo)          LOCAL_REPO_DIR="$2"; shift 2 ;;
    --repo-name)     REPO_NAME="$2"; shift 2 ;;
    --push)          DO_PUSH=true; shift ;;
    --remote)        REMOTE_GIT_URL="$2"; shift 2 ;;
    --branch)        GIT_BRANCH="$2"; shift 2 ;;
    --clean)         DO_CLEAN=true; shift ;;
    --sign)          SIGN_DB=true; shift ;;
    --quiet)         QUIET=true; shift ;;
    -h|--help)
      cat <<EOF
Usage: ./build.sh [options]
Options:
  --no-updpkgsums       Do not run updpkgsums before build
  --install             Install built packages locally (pacman -U)
  --repo <DIR>          Local binary repo dir (default: ${LOCAL_REPO_DIR})
  --repo-name <NAME>    Repo db name (default: ${REPO_NAME})
  --push                Git commit+push LOCAL_REPO_DIR to remote
  --remote <URL>        Remote Git URL (override)
  --branch <NAME>       Git branch to push (default: ${GIT_BRANCH})
  --clean               Clean src/pkg/old artifacts before build
  --sign                Sign repo db with GPG (repo-add -s)
  --quiet               Pass --quiet to makepkg
EOF
      exit 0
      ;;
    *)
      _die "Unknown option: $1"
      ;;
  esac
done

### ========= Checks =========
_have makepkg    || _die "makepkg not found"
_have repo-add   || _die "repo-add not found (pacman -S pacman-contrib)"
_have tar        || _die "tar not found"
[[ -f PKGBUILD ]] || _die "No PKGBUILD in current dir"

### ========= Clean =========
if $DO_CLEAN; then
  _info "Cleaning old artifacts..."
  rm -rf pkg src
  rm -f *.pkg.tar.* *.log
fi

### ========= Sums update (if local archives referenced) =========
if $RUN_UPDPKGSUMS; then
  if grep -E 'source=.*\.(tar\.(gz|xz|bz2|zst|lz|lz4|lzma)|7z|zip)' -q PKGBUILD; then
    if _have updpkgsums; then
      _info "Updating sha256sums..."
      updpkgsums
    else
      _info "updpkgsums not installed; skipping"
    fi
  fi
fi

### ========= Build =========
$QUIET && MAKEPKG_FLAGS+=("--quiet")
_info "Building with: makepkg ${MAKEPKG_FLAGS[*]}"
makepkg "${MAKEPKG_FLAGS[@]}"

mapfile -t BUILT_PKGS < <(ls -1 *.pkg.tar.* 2>/dev/null || true)
[[ ${#BUILT_PKGS[@]} -gt 0 ]] || _die "No built packages found"

_info "Built:"
printf ' - %s\n' "${BUILT_PKGS[@]}"

### ========= Optional install =========
if $DO_INSTALL; then
  _info "Installing locally..."
  sudo pacman -U --noconfirm "${BUILT_PKGS[@]}"
fi

### ========= Copy to repo dir =========
mkdir -p "${LOCAL_REPO_DIR}"
_info "Copying packages to ${LOCAL_REPO_DIR}"
for p in "${BUILT_PKGS[@]}"; do
  cp -f "$p" "${LOCAL_REPO_DIR}/"
done

### ========= Full DB rebuild (scan all packages) =========
cd "${LOCAL_REPO_DIR}"
shopt -s nullglob
ALL_PKGS=( *.pkg.tar.* )
[[ ${#ALL_PKGS[@]} -gt 0 ]] || _die "No packages in repo dir to index"

DB="${REPO_NAME}.db.tar.xz"
REPO_FLAGS=()
$SIGN_DB && REPO_FLAGS+=(-s)

_info "Rebuilding repo database from scratch: ${DB}"
# Remove old .db/.files to avoid stale entries, then rebuild over all packages.
rm -f "${REPO_NAME}.db"* "${REPO_NAME}.files"*
repo-add "${REPO_FLAGS[@]}" "${DB}" "${ALL_PKGS[@]}"

### ========= Optional Git commit+push =========
if $DO_PUSH; then
  _info "Git commit+push..."
  # Init git if needed
  if [[ ! -d .git ]]; then
    git init
    git checkout -b "${GIT_BRANCH}" || true
    # Set remote if provided or if using PAT
    [[ -n "${REMOTE_GIT_URL}" ]] && git remote add origin "${REMOTE_GIT_URL}"
  fi

  # Build auth URL if PAT is enabled
  if $USE_GITHUB_PAT; then
    # Token precedence: env > file
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
      TOKEN="${GITHUB_TOKEN}"
    elif [[ -f "${GITHUB_TOKEN_FILE}" ]]; then
      TOKEN="$(<"${GITHUB_TOKEN_FILE}")"
    else
      _die "USE_GITHUB_PAT=true but no GITHUB_TOKEN env or token file at ${GITHUB_TOKEN_FILE}"
    fi
    [[ -n "${REMOTE_GIT_URL}" ]] || REMOTE_GIT_URL="$(git remote get-url origin 2>/dev/null || true)"
    [[ -n "${REMOTE_GIT_URL}" ]] || _die "No remote URL; set --remote or configure origin"
    # inject PAT into https URL
    if [[ "${REMOTE_GIT_URL}" =~ ^https:// ]]; then
      proto_host="${REMOTE_GIT_URL#https://}"
      AUTH_URL="https://${GITHUB_USER}:${TOKEN}@${proto_host}"
      git remote remove origin 2>/dev/null || true
      git remote add origin "${AUTH_URL}"
    else
      _die "PAT injection requires https remote; got: ${REMOTE_GIT_URL}"
    fi
  fi

  git add -A
  git commit -m "repo(${REPO_NAME}): rebuild db and add packages ($(date -Iseconds))" || true
  git branch -M "${GIT_BRANCH}" || true
  # If remote not set yet and user forgot REMOTE_GIT_URL, instruct how to set
  if ! git remote get-url origin >/dev/null 2>&1; then
    _die "No 'origin' remote set. Set REMOTE_GIT_URL or add a remote manually and re-run with --push."
  fi
  git push -u origin "${GIT_BRANCH}"
fi

### ========= Cleanup (of build workspace) =========
# Do not delete packages in repo dir; only clean the PKGBUILD workspace (caller dir).
# We assume we were called from the package dir originally:
# Find the directory containing the PKGBUILD by inspecting PWD of parent shell if needed.
# Here we simply suggest the caller re-run with --clean next time if necessary.
_info "Done."

