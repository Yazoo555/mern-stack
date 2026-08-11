#!/usr/bin/env bash
# =============================================================================
# set-gh-secrets.sh — store your CURRENT AWS + Docker Hub credentials as GitHub
#                     Actions secrets (they change every time you log in)
#
# Training labs (e.g. VOC Labs) issue NEW temporary AWS credentials — always
# WITH a session token — every time the lab is stopped and restarted, and
# Docker Hub tokens can be rotated. This script re-syncs the repository
# secrets that the "Deploy MERN to EC2" workflow uses:
#
#   AWS_ACCESS_KEY_ID      access key id        (from the [default] block)
#   AWS_SECRET_ACCESS_KEY  secret access key    (from the [default] block)
#   AWS_SESSION_TOKEN      session token        (from the [default] block)
#   DOCKERHUB_USERNAME     Docker Hub username  (e.g. yazoo555)
#   DOCKERHUB_TOKEN        Docker Hub access token (dckr_pat_...)
#
# Usage — every time you log in again, just re-run:
#   ./set-gh-secrets.sh
#     ...uses ./gh-secrets.env (gitignored) if present, otherwise interactive.
#
# One-time setup (keeps a file you can edit instead of re-pasting):
#   cp gh-secrets.env.example gh-secrets.env
#   # edit gh-secrets.env with your current values
#   ./set-gh-secrets.sh
#
# Other options:
#   ./set-gh-secrets.sh --from-file gh-secrets.env   # explicit file
#   ./set-gh-secrets.sh --interactive                # paste, then Ctrl-D
#
# Environment:
#   GH_REPO    GitHub repo to set secrets on, e.g. Yazoo555/mern-stack
#              (default: detected from `git remote` / `gh repo view`)
# =============================================================================

set -euo pipefail

GH_REPO="${GH_REPO:-}"
FROM_FILE=""
INTERACTIVE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-file)
      [[ $# -ge 2 ]] || { echo "ERROR: --from-file needs a path argument." >&2; exit 1; }
      FROM_FILE="$2"; shift 2 ;;
    --interactive) INTERACTIVE=1; shift ;;
    -h|--help)
      sed -n '/^# ===/,/^# ===/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown option: $1 (use --from-file FILE or --interactive)" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Preflight: gh must be installed and logged in
# ---------------------------------------------------------------------------
command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI not found (see ghguide.txt section 4)." >&2; exit 1; }
if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: not logged in to GitHub. Run: gh auth login" >&2
  exit 1
fi

# Determine the target repository (strip any .git suffix / ssh prefix)
if [[ -z "$GH_REPO" ]]; then
  GH_REPO="$(git remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#.*[:/]([^/]+/[^/]+)$#\1#' || true)"
fi
if [[ -z "$GH_REPO" ]]; then
  GH_REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
fi
[[ -n "$GH_REPO" ]] || { echo "ERROR: could not detect the GitHub repo — set GH_REPO (e.g. Yazoo555/mern-stack)." >&2; exit 1; }
echo "Repository: $GH_REPO"
echo "------------------------------------------------------------"

# ---------------------------------------------------------------------------
# Parsing helpers (handle CRLF paste and both AWS + Docker Hub formats)
# ---------------------------------------------------------------------------
declare -A VALS

extract_key() { # $1=file  $2=key name -> first matching value (tolerates `export `)
  sed -n "s/^[[:space:]]*\(export[[:space:]]*\)\?${2}[[:space:]]*=[[:space:]]*\(.*\)\$/\2/p" "$1" | head -1 | tr -d '\r'
}

load_file() {
  local f="$1"
  [[ -f "$f" ]] || { echo "ERROR: file not found: $f" >&2; exit 1; }
  VALS[AWS_ACCESS_KEY_ID]="$(extract_key "$f" 'aws_access_key_id')"
  VALS[AWS_SECRET_ACCESS_KEY]="$(extract_key "$f" 'aws_secret_access_key')"
  VALS[AWS_SESSION_TOKEN]="$(extract_key "$f" 'aws_session_token')"
  # Docker Hub: DOCKERHUB_*= lines, or a "docker login -u <user>" line plus a bare dckr_pat_ token
  VALS[DOCKERHUB_USERNAME]="$(extract_key "$f" 'DOCKERHUB_USERNAME')"
  if [[ -z "${VALS[DOCKERHUB_USERNAME]:-}" ]]; then
    VALS[DOCKERHUB_USERNAME]="$(sed -n 's/^[[:space:]]*docker login -u[[:space:]]*\([^[:space:]]*\).*/\1/p' "$f" | head -1 | tr -d '\r')"
  fi
  VALS[DOCKERHUB_TOKEN]="$(extract_key "$f" 'DOCKERHUB_TOKEN')"
  if [[ -z "${VALS[DOCKERHUB_TOKEN]:-}" ]]; then
    VALS[DOCKERHUB_TOKEN]="$(grep -E '^[[:space:]]*dckr_pat_' "$f" | head -1 | tr -d '\r' | awk '{print $1}')"
  fi
}

interactive() {
  local tmp
  tmp="$(mktemp)"
  echo "Paste your current credentials below. Accepts the [default] AWS block"
  echo "(aws_access_key_id / aws_secret_access_key / aws_session_token) and"
  echo "Docker Hub values (DOCKERHUB_USERNAME= / DOCKERHUB_TOKEN=, or a"
  echo "'docker login -u <user>' line plus the dckr_pat_ token)."
  echo "Press Ctrl-D on a new line when done."
  echo "------------------------------------------------------------"
  cat > "$tmp" || { rm -f "$tmp"; echo "ERROR: failed to read input." >&2; exit 1; }
  load_file "$tmp"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Input source: explicit file > --interactive > gh-secrets.env > interactive
# ---------------------------------------------------------------------------
if [[ "$INTERACTIVE" -eq 1 ]]; then
  interactive
elif [[ -n "$FROM_FILE" ]]; then
  load_file "$FROM_FILE"
elif [[ -f "gh-secrets.env" ]]; then
  echo "Using ./gh-secrets.env ..."
  load_file "gh-secrets.env"
else
  echo "No gh-secrets.env found — switching to interactive paste."
  interactive
fi

# ---------------------------------------------------------------------------
# Validate: all 5 values must be present
# ---------------------------------------------------------------------------
missing=()
for k in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN DOCKERHUB_USERNAME DOCKERHUB_TOKEN; do
  [[ -n "${VALS[$k]:-}" ]] || missing+=("$k")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: missing value(s): ${missing[*]}" >&2
  echo "       Make sure gh-secrets.env has all 5 keys (see gh-secrets.env.example)." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Set the secrets
# ---------------------------------------------------------------------------
set_secret() {
  local name="$1" val="$2"
  # Pipe via stdin instead of --body so the value never appears in `ps` output.
  if ! printf '%s' "$val" | gh secret set "$name" --repo "$GH_REPO" >/dev/null 2>&1; then
    echo "ERROR: gh secret set $name failed." >&2
    return 1
  fi
  echo "  set $name (${#val} chars)"
}

echo "Setting GitHub Actions secrets on $GH_REPO ..."
set_secret AWS_ACCESS_KEY_ID      "${VALS[AWS_ACCESS_KEY_ID]}"
set_secret AWS_SECRET_ACCESS_KEY  "${VALS[AWS_SECRET_ACCESS_KEY]}"
set_secret AWS_SESSION_TOKEN      "${VALS[AWS_SESSION_TOKEN]}"
set_secret DOCKERHUB_USERNAME     "${VALS[DOCKERHUB_USERNAME]}"
set_secret DOCKERHUB_TOKEN        "${VALS[DOCKERHUB_TOKEN]}"

echo
  echo "Current secrets on $GH_REPO:"
  gh secret list --repo "$GH_REPO"
