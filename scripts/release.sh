#!/usr/bin/env bash
set -euo pipefail

# release.sh — Bump version, create release branch/tag, and open a PR.
#
# Usage: ./scripts/release.sh <patch|minor|major> [--dry-run]

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()  { echo -e "\033[0;36mℹ${NC} $*"; }
ok()    { echo -e "${GREEN}✔${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
die()   { echo -e "${RED}✖${NC} $*" >&2; exit 1; }
step()  { echo -e "${DIM}→${NC} $*"; }

BUMP=""
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    patch|minor|major) BUMP="$arg" ;;
    --dry-run) DRY_RUN=true ;;
    *) die "Unknown argument: $arg. Usage: ./scripts/release.sh <patch|minor|major> [--dry-run]" ;;
  esac
done

[ -n "$BUMP" ] || die "Version bump type required. Usage: ./scripts/release.sh <patch|minor|major> [--dry-run]"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# ── Preflight checks ─────────────────────────────────────────────────

step "Checking working tree..."
if [ -n "$(git status --porcelain)" ]; then
  die "Working tree is not clean. Commit or stash changes first."
fi

step "Checking current branch..."
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
  die "Must be on 'main' branch (currently on '$BRANCH')."
fi

step "Pulling latest from origin..."
git pull --ff-only origin main

# ── Version bump ──────────────────────────────────────────────────────

OLD_VERSION=$(node -p "require('./package.json').version")
step "Current version: $OLD_VERSION"

npm version "$BUMP" --no-git-tag-version > /dev/null
NEW_VERSION=$(node -p "require('./package.json').version")

# Also update the VERSION variable in the shell script.
sed -i.bak "s/^VERSION=\"$OLD_VERSION\"/VERSION=\"$NEW_VERSION\"/" bin/tunnel-cloud.sh
rm -f bin/tunnel-cloud.sh.bak

ok "Bumped version: ${BOLD}$OLD_VERSION${NC} → ${BOLD}$NEW_VERSION${NC}"

# ── Create release branch ────────────────────────────────────────────

RELEASE_BRANCH="release/v$NEW_VERSION"
step "Creating branch '$RELEASE_BRANCH'..."
git checkout -b "$RELEASE_BRANCH"

git add package.json bin/tunnel-cloud.sh
git commit -m "release: v$NEW_VERSION"

TAG="v$NEW_VERSION"
git tag "$TAG"

ok "Created commit and tag ${BOLD}$TAG${NC}"

if $DRY_RUN; then
  warn "Dry run — skipping push and PR creation."
  echo ""
  echo "  To undo:"
  echo "    git tag -d $TAG"
  echo "    git checkout main"
  echo "    git branch -D $RELEASE_BRANCH"
  echo "    git checkout -- package.json bin/tunnel-cloud.sh"
  exit 0
fi

# ── Push and create PR ───────────────────────────────────────────────

step "Pushing branch and tag..."
git push -u origin "$RELEASE_BRANCH"
git push origin "$TAG"

step "Creating pull request..."
PR_URL=$(gh pr create \
  --title "release: v$NEW_VERSION" \
  --body "Bumps version from \`$OLD_VERSION\` to \`$NEW_VERSION\`." \
  --base main \
  --head "$RELEASE_BRANCH")

echo ""
ok "Release ${BOLD}v$NEW_VERSION${NC} ready!"
echo "  PR: $PR_URL"
echo ""
echo "  Merge the PR to trigger npm publish and GitHub release."
