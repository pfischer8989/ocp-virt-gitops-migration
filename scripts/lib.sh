# shellcheck shell=bash
# Shared helpers. Source from other scripts:  source "$(dirname "$0")/lib.sh"
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "$REPO_ROOT/config.env" ]]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/config.env"
else
  # shellcheck disable=SC1091
  source "$REPO_ROOT/config.env.example"
fi

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m !\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m ✗\033[0m %s\n' "$*" >&2; exit 1; }

need() { for c in "$@"; do command -v "$c" >/dev/null || die "missing required command: $c"; done; }

require_oc_login() {
  need oc
  oc whoami >/dev/null 2>&1 || die "not logged in to OpenShift (run: oc login ...)"
  ok "OpenShift: $(oc whoami) @ $(oc whoami --show-server)"
}

# wait_for <description> <timeout-seconds> <command...>
wait_for() {
  local desc=$1 timeout=$2; shift 2
  local start=$SECONDS
  until "$@" >/dev/null 2>&1; do
    (( SECONDS - start > timeout )) && die "timed out after ${timeout}s waiting for: $desc"
    sleep 5
  done
  ok "$desc"
}

# Git helpers for the PR-driven demo steps -----------------------------------

require_clean_main() {
  need git gh
  cd "$REPO_ROOT"
  [[ -z "$(git status --porcelain -- migration-waves vms)" ]] \
    || die "uncommitted changes under migration-waves/ or vms/ - commit or stash first"
  git fetch -q origin "$REPO_BRANCH"
  git checkout -q "$REPO_BRANCH"
  git pull -q --ff-only origin "$REPO_BRANCH"
}

# open_pr <branch> <title> <body> <paths...>
open_pr() {
  local branch=$1 title=$2 body=$3; shift 3
  cd "$REPO_ROOT"
  git checkout -q -B "$branch"
  git add -- "$@"
  git commit -q -m "$title" -m "$body"
  git push -q -u origin "$branch" --force-with-lease
  local url
  url=$(gh pr create --repo "$GITHUB_REPO" --base "$REPO_BRANCH" --head "$branch" \
          --title "$title" --body "$body")
  git checkout -q "$REPO_BRANCH"
  ok "PR opened: $url"
  echo
  echo "Review and merge it in GitHub (or: gh pr merge --squash --delete-branch $url)"
}
