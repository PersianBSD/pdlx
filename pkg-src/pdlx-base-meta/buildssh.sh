#!/usr/bin/env bash
# build.sh — SSH-based Arch package builder & publisher for PdLinuXOS
# - Rebuilds full repo DB (scans all *.pkg.tar.*)
# - Copies built packages to a local binary repo dir
# - Git commit & push via SSH (no tokens)
# All inline comments are intentionally in English.

set -euo pipefail

### ======= Config (SSH-based) =======
REPO_NAME="pdlx-v1"                          # -> pdlx.db.tar.xz
LOCAL_REPO_DIR="/home/ali/pdlx-v1/x86_64"    # your local binary repo working dir

# SSH remote for the binary repo (must be a clone of this URL in LOCAL_REPO_DIR)
REMOTE_GIT_URL="git@github.com:PersianBSD/pdlx-v1.git"
GIT_BRANCH="main"

MAKEPKG_FLAGS=(-s --noconfirm)            # add --cleanbuild if desired
SIGN_DB=false                              # set true to use repo-add -s (requires GPG)
### ===================================

die(){ echo "ERROR: $*" >&2; exit 1; }
info(){ echo -e "\e[1;34m==>\e[0m $*"; }
have(){ command -v "$1" >/dev/null 2>&1; }

# CLI
RUN_UPDPKGSUMS=true
DO_INSTALL=false
DO_PUSH=true
DO_CLEAN=false
QUIET=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-updpkgsums) RUN_UPDPKGSUMS=false; shift ;;
    --install)       DO_INSTALL=true; shift ;;
    --repo)          LOCAL_REPO_DIR="$2"; shift 2 ;;
    --repo-name)     REPO_NAME="$2"; shift 2 ;;
    --push)          DO_PUSH=true; shift ;;
    --branch)        GIT_BRANCH="$2"; shift 2 ;;
    --clean)         DO_CLEAN=true; shift ;;
    --sign)          SIGN_DB=true; shift ;;
    --quiet)         QUIET=true; shift ;;
    -h|--help)
      cat <<EOF
Usage: ./build.sh [options]
  --no-updpkgsums   Skip updpkgsums
  --install         Install built package(s) (pacman -U)
  --repo DIR        Local binary repo dir (default: ${LOCAL_REPO_DIR})
  --repo-name NAME  Repo db prefix (default: ${REPO_NAME})
  --push            Git commit & push LOCAL_REPO_DIR via SSH
  --branch NAME     Git branch to push (default: ${GIT_BRANCH})
  --clean           Clean src/pkg/old artifacts before build
  --sign            Sign repo db (repo-add -s; requires GPG)
  --quiet           Pass --quiet to makepkg
EOF
      exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

# Checks
have makepkg  || die "makepkg not found"
have repo-add || die "repo-add not found (pacman -S pacman-contrib)"
have tar      || die "tar not found"
[[ -f PKGBUILD ]] || die "No PKGBUILD in current directory"

# Clean
if $DO_CLEAN; then
  info "Cleaning workspace..."
  rm -rf pkg src
  rm -f *.pkg.tar.* *.log
fi

# Update sums if local/remote archives referenced
if $RUN_UPDPKGSUMS; then
  if grep -E 'source=.*\.(tar\.(gz|xz|bz2|zst|lz|lz4|lzma)|7z|zip)' -q PKGBUILD; then
    if have updpkgsums; then
      info "Updating sha256sums (updpkgsums)..."
      updpkgsums
    else
      info "updpkgsums not installed; skipping"
    fi
  fi
fi

# Build
$QUIET && MAKEPKG_FLAGS+=("--quiet")
info "Building with: makepkg ${MAKEPKG_FLAGS[*]}"
makepkg "${MAKEPKG_FLAGS[@]}"

mapfile -t BUILT_PKGS < <(ls -1 *.pkg.tar.* 2>/dev/null || true)
[[ ${#BUILT_PKGS[@]} -gt 0 ]] || die "No built packages found"

info "Built packages:"
printf ' - %s\n' "${BUILT_PKGS[@]}"

# Optional local install
if $DO_INSTALL; then
  info "Installing locally..."
  sudo pacman -U --noconfirm "${BUILT_PKGS[@]}"
fi

# Copy to repo dir
mkdir -p "${LOCAL_REPO_DIR}"
info "Copying packages to ${LOCAL_REPO_DIR}"
for p in "${BUILT_PKGS[@]}"; do
  cp -f "$p" "${LOCAL_REPO_DIR}/"
done

# Full DB rebuild
cd "${LOCAL_REPO_DIR}"
shopt -s nullglob
ALL_PKGS=( *.pkg.tar.* )
[[ ${#ALL_PKGS[@]} -gt 0 ]] || die "No packages in ${LOCAL_REPO_DIR}"

DB="${REPO_NAME}.db.tar.xz"
REPO_FLAGS=()
$SIGN_DB && REPO_FLAGS+=(-s)

info "Rebuilding repo database from scratch: ${DB}"
rm -f "${REPO_NAME}.db"* "${REPO_NAME}.files"*
repo-add "${REPO_FLAGS[@]}" "${DB}" "${ALL_PKGS[@]}"

# Optional: SSH push
if $DO_PUSH; then
  info "Git commit & push via SSH..."
  if [[ ! -d .git ]]; then
    git init
    git checkout -b "${GIT_BRANCH}" || true
    git remote add origin "${REMOTE_GIT_URL}"
  fi

  # Ensure remote is SSH form
  current_url="$(git remote get-url origin 2>/dev/null || echo "")"
  if [[ -n "$current_url" && "$current_url" != "$REMOTE_GIT_URL" ]]; then
    git remote set-url origin "${REMOTE_GIT_URL}"
  fi

  git add -A
  git commit -m "repo(${REPO_NAME}): rebuild db & add packages ($(date -Iseconds))" || true
  git branch -M "${GIT_BRANCH}" || true
  # Push using your SSH agent/keys
  git push -u origin "${GIT_BRANCH}"
fi

info "Done."
