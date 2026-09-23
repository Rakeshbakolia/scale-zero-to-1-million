#!/usr/bin/env bash
# Pre-git-push: fail if common secret paths would be committed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FAIL=0

must_ignore() {
  local f="$1"
  if git check-ignore -q "$f" 2>/dev/null; then
    echo "OK (ignored): $f"
  else
    echo "FAIL: $f is NOT gitignored — do not commit" >&2
    FAIL=1
  fi
}

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "Not a git repo yet. After 'git init', run this script again."
fi

for f in terraform.tfvars terraform.tfstate terraform.tfstate.backup frontend/.env backend/.env; do
  [[ -e "$f" ]] && must_ignore "$f" || true
done

if [[ -d frontend/dist ]]; then
  must_ignore frontend/dist/
  if grep -rq "scalelab-aws-admin" frontend/dist 2>/dev/null; then
    echo "NOTE: frontend/dist contains baked VITE_ADMIN_API_KEY — keep dist/ ignored (never commit)."
  fi
fi

if git rev-parse --git-dir >/dev/null 2>&1; then
  if git ls-files --error-unmatch terraform.tfvars terraform.tfstate frontend/.env 2>/dev/null; then
    echo "FAIL: tracked secret/state file" >&2
    FAIL=1
  fi
  TRACKED=$(git ls-files | grep -E '(\.pem$|terraform\.tfvars$|terraform\.tfstate|frontend/\.env$|frontend/dist/)' || true)
  if [[ -n "$TRACKED" ]]; then
    echo "FAIL: these tracked files must be removed from git:" >&2
    echo "$TRACKED" >&2
    FAIL=1
  fi
fi

if rg -l 'AKIA[0-9A-Z]{16}' --glob '!node_modules/**' --glob '!.terraform/**' . 2>/dev/null; then
  echo "FAIL: possible AWS access key ID in repo" >&2
  FAIL=1
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "verify-safe-to-push: passed"
else
  exit 1
fi
