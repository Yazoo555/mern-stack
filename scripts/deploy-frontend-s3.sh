#!/usr/bin/env bash
# =============================================================================
# deploy-frontend-s3.sh — Build the React frontend into static files and deploy
#                         them to S3 + CloudFront (used by the frontend CI/CD
#                         workflow; also runnable locally).
#
#   Architecture:
#     Frontend (React/Vite) --vite build--> frontend/dist
#     --aws s3 sync--> S3 bucket  --CloudFront (OAI) or S3 website endpoint--> URL
#
#   The hosting mode is auto-detected: if the bucket has static website
#   hosting enabled (the fallback used when the AWS account blocks CloudFront),
#   the S3 website URL is printed and no CloudFront invalidation runs.
#   Otherwise the private-bucket + CloudFront setup from
#   setup-frontend-hosting.sh is used and the cache is invalidated.
#
#   The EC2 instance runs ONLY the backend/API (Docker, port 5000). The
#   frontend calls it via VITE_API_URL, which Vite bakes into the bundle at
#   BUILD time — so it must be passed to `vite build`, not to a running server.
#
#   Usage:
#     API_URL=http://1.2.3.4:5000 ./scripts/deploy-frontend-s3.sh
#
#   Environment variables:
#     API_URL                      backend base URL baked into the build
#                                  (required in CI; default http://localhost:5000)
#     S3_BUCKET                    bucket name (default mern-expense-tracker-frontend-<account>)
#     CLOUDFRONT_DISTRIBUTION_ID   distribution to invalidate (optional — otherwise
#                                  auto-discovered via the Name=mern-frontend-cdn tag)
#     FRONTEND_DIR                 frontend project dir (default ./frontend)
#     AWS_REGION                   region (default us-east-1)
#
#   Requires the same AWS credentials as the rest of the repo (see
#   set-gh-secrets.sh / set-aws-creds.sh). Run ./scripts/setup-frontend-hosting.sh
#   once first to create the bucket and CloudFront distribution.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Logging helpers (same style as the other deploy scripts)
# ---------------------------------------------------------------------------
if [[ -t 1 && "${CI:-}" != "true" ]]; then
  C_BOLD=$'\e[1m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_RESET=$'\e[0m'
else
  C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi
log()  { echo -e "${C_BOLD}${C_GREEN}[deploy-frontend]${C_RESET} $*"; }
warn() { echo -e "${C_BOLD}${C_YELLOW}[deploy-frontend] WARN:${C_RESET} $*" >&2; }
die()  { echo -e "${C_BOLD}${C_RED}[deploy-frontend] ERROR:${C_RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND_DIR="${FRONTEND_DIR:-$SCRIPT_DIR/../frontend}"
API_URL="${API_URL:-http://localhost:5000}"
S3_BUCKET="${S3_BUCKET:-}"
CLOUDFRONT_DISTRIBUTION_ID="${CLOUDFRONT_DISTRIBUTION_ID:-}"
CLOUDFRONT_TAG_NAME="${CLOUDFRONT_TAG_NAME:-mern-frontend-cdn}"
AWS_REGION="${AWS_REGION:-us-east-1}"

export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
command -v aws >/dev/null || die "aws CLI not found"
command -v npm >/dev/null || die "npm not found"
[[ -f "$FRONTEND_DIR/package.json" ]] || die "No package.json in $FRONTEND_DIR (set FRONTEND_DIR)"
[[ -f "$FRONTEND_DIR/package-lock.json" ]] || warn "No package-lock.json in $FRONTEND_DIR — using 'npm install' instead of 'npm ci'"

log "Checking AWS credentials (region: $AWS_REGION) ..."
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
  || die "AWS credentials invalid/expired. Run './set-aws-creds.sh' or set the AWS_* env vars."

# Default bucket name matches setup-frontend-hosting.sh
if [[ -z "$S3_BUCKET" ]]; then
  S3_BUCKET="mern-expense-tracker-frontend-${ACCOUNT_ID}"
fi

# ---------------------------------------------------------------------------
# 1) Build static files (VITE_API_URL is baked in at build time)
# ---------------------------------------------------------------------------
log "Building frontend (VITE_API_URL=$API_URL) ..."
(
  cd "$FRONTEND_DIR"
  if [[ -f package-lock.json ]]; then
    npm ci
  else
    npm install
  fi
  VITE_API_URL="$API_URL" npm run build
)

[[ -d "$FRONTEND_DIR/dist" ]] || die "Build finished but $FRONTEND_DIR/dist is missing — check 'npm run build'."

# ---------------------------------------------------------------------------
# 2) Upload to S3 (the bucket is private; CloudFront reads it via OAC)
# ---------------------------------------------------------------------------
log "Uploading dist/ to s3://$S3_BUCKET ..."
aws s3 sync "$FRONTEND_DIR/dist" "s3://$S3_BUCKET" --delete --region "$AWS_REGION" \
  || die "s3 sync failed — check the bucket exists (run ./scripts/setup-frontend-hosting.sh once) and that S3_BUCKET is right."

# ---------------------------------------------------------------------------
# 3) Invalidate CloudFront so users immediately get the new files
#    (skipped automatically when the bucket is an S3 static website instead)
# ---------------------------------------------------------------------------
if aws s3api get-bucket-website --bucket "$S3_BUCKET" --query 'IndexDocument.Suffix' --output text >/dev/null 2>&1; then
  # S3 static website mode (set up by setup-frontend-hosting.sh when the
  # account blocks CloudFront) — new files are served immediately, no
  # invalidation exists.
  log "Frontend URL: http://${S3_BUCKET}.s3-website-${AWS_REGION}.amazonaws.com"
else
  DIST_ID="$CLOUDFRONT_DISTRIBUTION_ID"
  if [[ -z "$DIST_ID" ]]; then
    DIST_ARN="$(aws resourcegroupstaggingapi get-resources \
      --resource-type-filters cloudfront:distribution \
      --tag-filters "Key=Name,Values=${CLOUDFRONT_TAG_NAME}" \
      --query 'ResourceTagMappingList[0].ResourceARN' --output text 2>/dev/null || true)"
    if [[ -n "$DIST_ARN" && "$DIST_ARN" != "None" ]]; then
      DIST_ID="${DIST_ARN##*/}"
    fi
  fi

  if [[ -n "$DIST_ID" ]]; then
    log "Invalidating CloudFront distribution $DIST_ID ..."
    aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths "/*" \
      --query 'Invalidation.Id' --output text >/dev/null \
      || warn "Invalidation failed (check cloudfront:CreateInvalidation permission)."
    DOMAIN="$(aws cloudfront get-distribution --id "$DIST_ID" --query 'Distribution.DomainName' --output text 2>/dev/null || true)"
    log "Frontend URL: https://${DOMAIN:-<distribution domain>}"
  else
    warn "No CloudFront distribution found (tag '$CLOUDFRONT_TAG_NAME') — files were uploaded to S3 but no cache was invalidated."
  fi
fi

log "Deploy complete."
