#!/usr/bin/env bash
# =============================================================================
# setup-frontend-hosting.sh — One-time AWS setup for serving the React frontend
#                              from S3 (instead of EC2).
#
#   Architecture:
#     Frontend (React/Vite) --vite build--> static files in frontend/dist
#     --aws s3 sync--> S3 bucket  --CloudFront (OAI) or S3 website endpoint--> URL
#
#   The EC2 instance keeps running ONLY the backend/API (Docker, port 5000).
#
#   This script auto-detects what the AWS account allows:
#
#     • CloudFront available  → private bucket + CloudFront distribution
#       (Origin Access Identity) → HTTPS URL (best practice)
#     • CloudFront blocked    → S3 static website hosting (public-read bucket
#       policy) → http://<bucket>.s3-website-<region>.amazonaws.com
#
#   Some training labs (e.g. VOC Labs) deny every cloudfront:* API; the script
#   detects that and falls back to S3 website hosting automatically, so the
#   deploy pipeline keeps working either way.
#
#   What this script does (all idempotent — safe to re-run):
#     1. Creates the S3 bucket if it does not exist yet
#        (default name: mern-expense-tracker-frontend-<ACCOUNT_ID>)
#     2. Probes CloudFront access and picks a mode (see above)
#     3. Writes the bucket policy (CloudFront-only, or public-read for S3 mode)
#     4. Prints the frontend URL and the values the deploy script needs
#
#   Usage:
#     ./scripts/setup-frontend-hosting.sh
#
#   Environment variables (all optional):
#     AWS_REGION                    region (default us-east-1)
#     S3_BUCKET                     bucket name (default mern-expense-tracker-frontend-<account>)
#     CLOUDFRONT_TAG_NAME           tag used to find/reuse the distribution (default mern-frontend-cdn)
#     CLOUDFRONT_DISTRIBUTION_ID    adopt an existing distribution instead of creating one
#     CLOUDFRONT_PRICE_CLASS        PriceClass_100 | PriceClass_200 | PriceClass_All (default PriceClass_100)
#
#   After running this once, deploys are fully automatic via the
#   "Frontend CI/CD (S3 + CloudFront)" GitHub Actions workflow — no extra
#   secrets are needed because the deploy script reuses the same bucket-name
#   convention and auto-detects the mode.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Logging helpers (same style as deploy.sh / destroy.sh)
# ---------------------------------------------------------------------------
if [[ -t 1 && "${CI:-}" != "true" ]]; then
  C_BOLD=$'\e[1m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_RESET=$'\e[0m'
else
  C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi
log()  { echo -e "${C_BOLD}${C_GREEN}[setup-frontend]${C_RESET} $*"; }
warn() { echo -e "${C_BOLD}${C_YELLOW}[setup-frontend] WARN:${C_RESET} $*" >&2; }
die()  { echo -e "${C_BOLD}${C_RED}[setup-frontend] ERROR:${C_RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
AWS_REGION="${AWS_REGION:-us-east-1}"
S3_BUCKET="${S3_BUCKET:-}"
CLOUDFRONT_TAG_NAME="${CLOUDFRONT_TAG_NAME:-mern-frontend-cdn}"
CLOUDFRONT_DISTRIBUTION_ID="${CLOUDFRONT_DISTRIBUTION_ID:-}"
CLOUDFRONT_PRICE_CLASS="${CLOUDFRONT_PRICE_CLASS:-PriceClass_100}"
OAI_COMMENT="mern-frontend-oai"        # used to find/reuse the Origin Access Identity

export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""

TMP_FILES=()
cleanup() { for f in "${TMP_FILES[@]:-}"; do rm -f "$f"; done; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
command -v aws >/dev/null || die "aws CLI not found"
log "Checking AWS credentials (region: $AWS_REGION) ..."
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
  || die "AWS credentials invalid/expired. Run './set-aws-creds.sh' or set the AWS_* env vars."
log "AWS identity OK (account $ACCOUNT_ID)"

# Default bucket name embeds the account id so it is globally unique
if [[ -z "$S3_BUCKET" ]]; then
  S3_BUCKET="mern-expense-tracker-frontend-${ACCOUNT_ID}"
fi

# ---------------------------------------------------------------------------
# 1) S3 bucket (create if missing)
# ---------------------------------------------------------------------------
if aws s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1; then
  log "S3 bucket '$S3_BUCKET' already exists."
else
  log "Creating S3 bucket '$S3_BUCKET' ..."
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION" >/dev/null \
      || die "Could not create bucket '$S3_BUCKET'. The name may already be taken by another AWS account — set S3_BUCKET to a unique name."
  else
    aws s3api create-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null \
      || die "Could not create bucket '$S3_BUCKET'. The name may already be taken by another AWS account — set S3_BUCKET to a unique name."
  fi
  log "Bucket created."
fi

# ---------------------------------------------------------------------------
# 2) Probe CloudFront access — pick the hosting mode
# ---------------------------------------------------------------------------
MODE="cloudfront"
if ! err="$(aws cloudfront list-distributions --max-items 1 2>&1 >/dev/null)"; then
  if grep -Eq 'AccessDenied|denied|UnauthorizedOperation|not authorized' <<< "$err"; then
    warn "CloudFront is blocked for this AWS account (${err}) —"
    warn "falling back to S3 static website hosting (no CloudFront)."
    MODE="s3-website"
  else
    die "Unexpected AWS error probing CloudFront: $err"
  fi
fi

# ---------------------------------------------------------------------------
# 3) Configure the bucket per mode
# ---------------------------------------------------------------------------
POLICY_FILE="$(mktemp)"
TMP_FILES+=("$POLICY_FILE")

if [[ "$MODE" == "s3-website" ]]; then
  # ---- S3 static website hosting: bucket must ALLOW a public-read policy ----
  log "Enabling S3 static website hosting on '$S3_BUCKET' ..."
  aws s3api put-public-access-block --bucket "$S3_BUCKET" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false \
    >/dev/null 2>&1 \
    || warn "Could not set bucket public-access-block — if the account blocks public access by default, the policy below will be rejected."
  aws s3 website "s3://$S3_BUCKET" --index-document index.html --error-document index.html >/dev/null \
    || die "Could not enable static website hosting (needs s3:PutBucketWebsite)."

  cat > "$POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${S3_BUCKET}/*"
    }
  ]
}
EOF
  log "Writing public-read bucket policy (S3 website mode) ..."
  aws s3api put-bucket-policy --bucket "$S3_BUCKET" --policy "file://$POLICY_FILE" >/dev/null \
    || die "Could not write the public-read bucket policy (needs s3:PutBucketPolicy). If 'Block all public access' is enabled at the ACCOUNT level (S3 console → Block Public Access), disable it and re-run."
  FRONTEND_URL="http://${S3_BUCKET}.s3-website-${AWS_REGION}.amazonaws.com"
  DIST_ID=""

else
  # ---- CloudFront mode: bucket stays PRIVATE, only CloudFront reads it ----
  aws s3api put-public-access-block --bucket "$S3_BUCKET" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
    >/dev/null 2>&1 || warn "Could not set public-access-block on the bucket (lab may deny it) — check the bucket is not public."

  # 3a) Origin Access Identity (get or create)
  OAI_ID="$(aws cloudfront list-cloud-front-origin-access-identities \
    --query "CloudFrontOriginAccessIdentityList.Items[?Comment=='${OAI_COMMENT}'].Id" \
    --output text 2>/dev/null || true)"
  if [[ -n "$OAI_ID" ]]; then
    log "Reusing Origin Access Identity '$OAI_COMMENT' ($OAI_ID)."
  else
    log "Creating Origin Access Identity '$OAI_COMMENT' ..."
    OAI_ID="$(aws cloudfront create-cloud-front-origin-access-identity \
      --cloud-front-origin-access-identity-config \
        "CallerReference=${OAI_COMMENT}-$(date +%s),Comment=${OAI_COMMENT}" \
      --query 'CloudFrontOriginAccessIdentity.Id' --output text)" \
      || die "Could not create the CloudFront Origin Access Identity. Your AWS account needs cloudfront:CreateCloudFrontOriginAccessIdentity."
    log "OAI created: $OAI_ID"
  fi

  # 3b) Distribution (reuse by tag, adopt via env, or create)
  DIST_ID=""
  if [[ -n "$CLOUDFRONT_DISTRIBUTION_ID" ]]; then
    DIST_ID="$CLOUDFRONT_DISTRIBUTION_ID"
    log "Using CLOUDFRONT_DISTRIBUTION_ID=$DIST_ID"
  else
    DIST_ARN="$(aws resourcegroupstaggingapi get-resources \
      --resource-type-filters cloudfront:distribution \
      --tag-filters "Key=Name,Values=${CLOUDFRONT_TAG_NAME}" \
      --query 'ResourceTagMappingList[0].ResourceARN' --output text 2>/dev/null || true)"
    if [[ -n "$DIST_ARN" && "$DIST_ARN" != "None" ]]; then
      DIST_ID="${DIST_ARN##*/}"
      log "Reusing existing CloudFront distribution $DIST_ID (tag $CLOUDFRONT_TAG_NAME)."
    fi
  fi

  if [[ -z "$DIST_ID" ]]; then
    log "Creating CloudFront distribution (this deploys in ~5 minutes) ..."
    CFG_FILE="$(mktemp)"
    TMP_FILES+=("$CFG_FILE")
    cat > "$CFG_FILE" <<EOF
{
  "CallerReference": "mern-frontend-$(date +%s)",
  "Comment": "MERN Expense Tracker frontend (S3 + OAI, served from S3/CloudFront)",
  "Enabled": true,
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "S3-${S3_BUCKET}",
        "DomainName": "${S3_BUCKET}.s3.${AWS_REGION}.amazonaws.com",
        "OriginPath": "",
        "S3OriginConfig": { "OriginAccessIdentity": "origin-access-identity/cloudfront/${OAI_ID}" }
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "S3-${S3_BUCKET}",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 2,
      "Items": ["GET", "HEAD"],
      "CachedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] }
    },
    "Compress": true,
    "ForwardedValues": {
      "QueryString": false,
      "Cookies": { "Forward": "none" },
      "Headers": { "Quantity": 0, "Items": [] }
    },
    "MinTTL": 0,
    "DefaultTTL": 86400,
    "MaxTTL": 31536000
  },
  "PriceClass": "${CLOUDFRONT_PRICE_CLASS}",
  "Aliases": { "Quantity": 0, "Items": [] }
}
EOF
    if ! DIST_ID="$(aws cloudfront create-distribution \
        --distribution-config "file://$CFG_FILE" \
        --query 'Distribution.Id' --output text 2>&1)"; then
      if grep -Eq 'AccessDenied|denied|not authorized' <<< "$DIST_ID"; then
        warn "CloudFront is blocked for this AWS account — cannot create a distribution."
        warn "Switch to S3 static website hosting instead: run the script with"
        warn "the account-level public access block disabled (see the S3 mode above), or"
        warn "use an AWS account that allows cloudfront:CreateDistribution."
        die "CloudFront blocked: $DIST_ID"
      else
        die "Could not create the CloudFront distribution: $DIST_ID"
      fi
    fi
    log "Distribution $DIST_ID created."

    DIST_ARN="arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DIST_ID}"
    aws cloudfront tag-resource --resource "$DIST_ARN" \
      --tags "Items=[{Key=Name,Value=${CLOUDFRONT_TAG_NAME}}]" >/dev/null 2>&1 \
      || warn "Could not tag the distribution (lab may deny cloudfront:TagResource) — set CLOUDFRONT_DISTRIBUTION_ID on future runs instead."

    log "Waiting for distribution to deploy (this can take ~5 minutes) ..."
    local_status="InProgress"
    for _ in $(seq 1 90); do
      local_status="$(aws cloudfront get-distribution --id "$DIST_ID" --query 'Distribution.Status' --output text 2>/dev/null || echo InProgress)"
      [[ "$local_status" == "Deployed" ]] && break
      sleep 10
    done
    [[ "$local_status" == "Deployed" ]] \
      || warn "Distribution still '$local_status' after waiting — it should finish shortly; the URL below will work once deployed."
  fi

  DIST_ARN="arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DIST_ID}"
  DOMAIN="$(aws cloudfront get-distribution --id "$DIST_ID" --query 'Distribution.DomainName' --output text)"

  cat > "$POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::cloudfront:user/CloudFront Origin Access Identity ${OAI_ID}" },
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${S3_BUCKET}/*",
      "Condition": { "StringEquals": { "AWS:SourceArn": "${DIST_ARN}" } }
    }
  ]
}
EOF
  log "Writing bucket policy (CloudFront-only read access) ..."
  aws s3api put-bucket-policy --bucket "$S3_BUCKET" --policy "file://$POLICY_FILE" >/dev/null \
    || die "Could not write the bucket policy (needs s3:PutBucketPolicy). The distribution will return 403 until this succeeds."

  FRONTEND_URL="https://$DOMAIN"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
log "======================== FRONTEND HOSTING READY ========================"
log "mode=$MODE"
log "s3_bucket=$S3_BUCKET"
if [[ -n "${DIST_ID:-}" ]]; then
  log "cloudfront_distribution_id=$DIST_ID"
fi
log "frontend_url=$FRONTEND_URL"
log "backend_url=http://<EC2_HOST>:5000   (baked into the build via VITE_API_URL)"
echo
log "Next steps:"
log "  1. Push to main (or run the workflow manually) so the CI build + deploy"
log "     uploads the frontend to S3."
log "  2. Open $FRONTEND_URL"
log "======================================================================="
