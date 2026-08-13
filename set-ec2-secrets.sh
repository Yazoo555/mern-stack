#!/usr/bin/env bash
# =============================================================================
# set-ec2-secrets.sh — store your EC2 connection details as GitHub Actions
#                      secrets for the deploy jobs in backend.yml / frontend.yml
#
# Sets three secrets:
#   EC2_HOST       public IP of your EC2 instance (from the AWS console)
#   EC2_USER       SSH login user, e.g. ec2-user (Amazon Linux)
#   EC2_SSH_KEY    the ENTIRE contents of your .pem key (BEGIN to END lines)
#
# Usage — every time you launch/replace the EC2 instance, just re-run:
#   ./set-ec2-secrets.sh --key ~/.ssh/mern-ec2-key.pem
#
# One-time setup (keeps a file you can edit instead of re-pasting):
#   cp ec2-secrets.env.example ec2-secrets.env
#   # edit ec2-secrets.env (EC2_HOST, EC2_USER, and EC2_SSH_KEY_FILE)
#   ./set-ec2-secrets.sh
#
# Other options:
#   ./set-ec2-secrets.sh --from-file ec2-secrets.env   # explicit file
#   ./set-ec2-secrets.sh --interactive                # paste host/user, then PEM
#
# Environment:
#   GH_REPO    GitHub repo to set secrets on, e.g. Yazoo555/mern-stack
#              (default: detected from `git remote` / `gh repo view`)
# =============================================================================

set -euo pipefail

GH_REPO="${GH_REPO:-}"
FROM_FILE=""
KEY_FILE=""
INTERACTIVE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key)
      [[ $# -ge 2 ]] || { echo "ERROR: --key needs a PEM file path." >&2; exit 1; }
      KEY_FILE="$2"; shift 2 ;;
    --from-file)
      [[ $# -ge 2 ]] || { echo "ERROR: --from-file needs a path." >&2; exit 1; }
      FROM_FILE="$2"; shift 2 ;;
    --interactive) INTERACTIVE=1; shift ;;
    -h|--help)
      sed -n '/^# ===/,/^# ===/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown option: $1 (use --key FILE, --from-file FILE, or --interactive)" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Preflight: gh must be installed and logged in
# ---------------------------------------------------------------------------
command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI not found (see ghguide.txt)." >&2; exit 1; }
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
# Value extraction: first "KEY=value" line (tolerates `export ` prefix and
# CRLF line endings). Implemented with awk so there are no shell/sed
# backslash-escaping pitfalls.
# ---------------------------------------------------------------------------
extract_key() { # $1=file  $2=key name -> first matching value (tolerates `export `)
  awk -v key="$2" '
    { line = $0 }
    line ~ "^[[:space:]]*export[[:space:]]+" { sub(/^[[:space:]]*export[[:space:]]+/, "", line) }
    line ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", line)
      print line
      exit
    }' "$1" | head -1 | tr -d '\r'
}

EC2_HOST=""
EC2_USER=""
EC2_SSH_KEY=""

# ---------------------------------------------------------------------------
# PEM reader: validates the file really is a key (BEGIN .. END)
# ---------------------------------------------------------------------------
read_pem() {
  local f="$1"
  [[ -f "$f" ]] || { echo "ERROR: key file not found: $f" >&2; exit 1; }
  EC2_SSH_KEY="$(cat "$f")"
  grep -q -- '-----BEGIN' <<< "$EC2_SSH_KEY" \
    || { echo "ERROR: $f does not look like a PEM key (no -----BEGIN line)." >&2; exit 1; }
  grep -q -- '-----END' <<< "$EC2_SSH_KEY" \
    || { echo "ERROR: $f is missing the -----END line — the WHOLE .pem file is needed." >&2; exit 1; }
  echo "  read PEM key from $f"
}

# ---------------------------------------------------------------------------
# Input source: explicit --key / --from-file > ec2-secrets.env > interactive
# ---------------------------------------------------------------------------
if [[ -n "$KEY_FILE" ]]; then
  read_pem "$KEY_FILE"
elif [[ "$INTERACTIVE" -eq 1 ]]; then
  :
elif [[ -n "$FROM_FILE" ]]; then
  [[ -f "$FROM_FILE" ]] || { echo "ERROR: file not found: $FROM_FILE" >&2; exit 1; }
  EC2_HOST="$(extract_key "$FROM_FILE" 'EC2_HOST')"
  EC2_USER="$(extract_key "$FROM_FILE" 'EC2_USER')"
  local_pem="$(extract_key "$FROM_FILE" 'EC2_SSH_KEY_FILE')"
  [[ -z "$EC2_SSH_KEY" ]] && EC2_SSH_KEY="$(extract_key "$FROM_FILE" 'EC2_SSH_KEY')"
  if [[ -z "$EC2_SSH_KEY" && -n "$local_pem" ]]; then
    read_pem "${local_pem/#\~/$HOME}"
  fi
elif [[ -f "ec2-secrets.env" ]]; then
  echo "Using ./ec2-secrets.env ..."
  EC2_HOST="$(extract_key "ec2-secrets.env" 'EC2_HOST')"
  EC2_USER="$(extract_key "ec2-secrets.env" 'EC2_USER')"
  local_pem="$(extract_key "ec2-secrets.env" 'EC2_SSH_KEY_FILE')"
  EC2_SSH_KEY="$(extract_key "ec2-secrets.env" 'EC2_SSH_KEY')"
  if [[ -z "$EC2_SSH_KEY" && -n "$local_pem" ]]; then
    read_pem "${local_pem/#\~/$HOME}"
  fi
else
  echo "No ec2-secrets.env found — switching to interactive input."
fi

# ---------------------------------------------------------------------------
# Interactive fallback for anything still missing
# ---------------------------------------------------------------------------
if [[ -z "$EC2_HOST" ]]; then
  read -r -p "EC2 public IP (EC2_HOST): " EC2_HOST
fi
if [[ -z "$EC2_USER" ]]; then
  read -r -p "SSH user (EC2_USER) [ec2-user]: " ans
  EC2_USER="${ans:-ec2-user}"
fi
if [[ -z "$EC2_SSH_KEY" ]]; then
  echo "Paste the ENTIRE contents of your .pem file (from -----BEGIN to -----END,"
  echo "inclusive), then press Ctrl-D on a new line:"
  EC2_SSH_KEY="$(cat)"
fi

# ---------------------------------------------------------------------------
# Validate: all three values must be present
# ---------------------------------------------------------------------------
missing=()
[[ -n "$EC2_HOST" ]]   || missing+=("EC2_HOST")
[[ -n "$EC2_USER" ]]   || missing+=("EC2_USER")
[[ -n "$EC2_SSH_KEY" ]] || missing+=("EC2_SSH_KEY")
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: missing value(s): ${missing[*]}" >&2
  exit 1
fi
grep -q -- '-----BEGIN' <<< "$EC2_SSH_KEY" \
  || { echo "ERROR: EC2_SSH_KEY does not look like a PEM key (no -----BEGIN line)." >&2; exit 1; }
grep -q -- '-----END' <<< "$EC2_SSH_KEY" \
  || { echo "ERROR: EC2_SSH_KEY is missing the -----END line — the WHOLE .pem file is needed." >&2; exit 1; }

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
set_secret EC2_HOST     "$EC2_HOST"
set_secret EC2_USER     "$EC2_USER"
set_secret EC2_SSH_KEY  "$EC2_SSH_KEY"

echo
echo "Current secrets on $GH_REPO:"
gh secret list --repo "$GH_REPO"
