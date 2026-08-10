#!/usr/bin/env bash
# =============================================================================
# set-aws-creds.sh — paste fresh AWS lab credentials for deploy.sh
#
# Training labs (e.g. VOC Labs) issue NEW temporary AWS credentials every time
# the lab is stopped and restarted. Run this script after each lab start, paste
# the [default] block from the lab's "AWS Details" panel, and it will:
#
#   1. Back up your current ~/.aws/credentials (timestamped .bak file)
#   2. Save the new credentials there (permissions locked to 600)
#   3. Verify them with `aws sts get-caller-identity`
#   4. Probe EC2 access so you know immediately whether deploy.sh can run
#
# Usage:
#   ./set-aws-creds.sh
#   ... paste the credentials block ...
#   ... press Ctrl-D on a new line ...
#   ./deploy.sh
#
# Environment:
#   AWS_CREDS_FILE   override the credentials file path (default ~/.aws/credentials)
#   AWS_REGION       region used for the EC2 probe (default us-east-1)
# =============================================================================

set -euo pipefail

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found (install it first)." >&2; exit 1; }

CREDS_FILE="${AWS_CREDS_FILE:-$HOME/.aws/credentials}"
TMP="$(mktemp)"

echo "Paste your new AWS credentials below (the whole [default] block from the"
echo "lab's 'AWS Details' panel). When you are done, press Ctrl-D on a new line."
echo "------------------------------------------------------------------------"

cat > "$TMP" || { rm -f "$TMP"; echo "ERROR: failed to read input." >&2; exit 1; }

# Normalize: strip CRLF (Windows copy-paste) and drop blank lines
sed -i 's/\r$//' "$TMP"
sed -i '/^[[:space:]]*$/d' "$TMP"

# The three keys that must be present (lab credentials always include a session token)
if ! grep -q '^[[:space:]]*aws_access_key_id=' "$TMP" || \
   ! grep -q '^[[:space:]]*aws_secret_access_key=' "$TMP" || \
   ! grep -q '^[[:space:]]*aws_session_token=' "$TMP"; then
  rm -f "$TMP"
  echo "ERROR: the paste must contain aws_access_key_id, aws_secret_access_key" >&2
  echo "       and aws_session_token lines (as shown in the lab panel)." >&2
  echo "       Nothing was saved." >&2
  exit 1
fi

# Normalize to exactly "[default]" + the three aws_* lines. Handles any paste
# variant: with or without a section header, or with a differently-named section.
# (No `&&` here — if the write fails, set -e aborts before any file is saved.)
{
  echo '[default]'
  grep -E '^[[:space:]]*(aws_access_key_id|aws_secret_access_key|aws_session_token)=' "$TMP"
} > "${TMP}.new"
mv "${TMP}.new" "$TMP"

# Back up the previous credentials before overwriting
if [[ -f "$CREDS_FILE" ]]; then
  bak="${CREDS_FILE}.bak.$(date +%s)"
  cp "$CREDS_FILE" "$bak"
  echo "Backed up previous credentials to $bak"
fi

mkdir -p "$(dirname "$CREDS_FILE")"
mv "$TMP" "$CREDS_FILE"
chmod 600 "$CREDS_FILE"
echo "Saved new credentials to $CREDS_FILE"

# Validate the saved credentials
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
export AWS_PAGER=""
if ! identity="$(aws sts get-caller-identity --query Arn --output text 2>&1)"; then
  echo "WARN: credentials were saved, but AWS rejected them:" >&2
  echo "  $identity" >&2
  echo "Double-check that you pasted the CURRENT lab credentials." >&2
  exit 1
fi
echo "AWS identity OK: $identity"

# Probe EC2 access — tells you right away whether deploy.sh can run
if aws ec2 describe-regions --query 'Regions[0].RegionName' --output text >/dev/null 2>&1; then
  echo "EC2 access OK — you can now run: ./deploy.sh"
else
  echo "WARN: EC2 access is still denied (explicit deny, e.g. policy 'voc-cancel-cred')." >&2
  echo "      This lab session is still blocked. Try: End Lab -> wait 15-30 min -> Start Lab," >&2
  echo "      or contact your lab provider/instructor, or use an AWS account with EC2 access." >&2
  exit 1
fi
