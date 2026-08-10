#!/usr/bin/env bash
# =============================================================================
# destroy.sh — Tears down the AWS resources created by deploy.sh:
#
#   • Terminates EC2 instances tagged $INSTANCE_NAME (default: mern-app-server)
#   • Releases the Elastic IPs deploy.sh attached (tagged $INSTANCE_NAME, or
#     set via EIP_ALLOCATION_ID) so they don't keep being billed
#   • Deletes the EC2 key pair $KEY_NAME         (default: mern-ec2-key)
#   • Deletes the security group $SG_NAME        (default: mern-app-sg)
#
#   Safety:
#   • Asks for confirmation before deleting anything (skip with -y/--yes,
#     or automatically in CI)
#   • --dry-run prints exactly what would be deleted without deleting anything
#   • --delete-key-file also removes the local PEM at $KEY_PATH (off by default)
#   • Idempotent — already-deleted resources are reported and skipped
#   • OUTPUT_FILE appends machine-readable results (e.g. $GITHUB_OUTPUT)
#
#   Usage:
#     ./destroy.sh [--yes] [--dry-run] [--delete-key-file] [--help]
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Logging helpers (same style as deploy.sh; colors disabled in CI / non-TTY)
# ---------------------------------------------------------------------------
if [[ -t 1 && "${CI:-}" != "true" ]]; then
  C_BOLD=$'\e[1m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_RESET=$'\e[0m'
else
  C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi
log()  { echo -e "${C_BOLD}${C_GREEN}[destroy]${C_RESET} $*"; }
warn() { echo -e "${C_BOLD}${C_YELLOW}[destroy] WARN:${C_RESET} $*" >&2; }
die()  { echo -e "${C_BOLD}${C_RED}[destroy] ERROR:${C_RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Configuration (mirror deploy.sh defaults so the two scripts stay in sync)
# ---------------------------------------------------------------------------
AWS_REGION="${AWS_REGION:-us-east-1}"
KEY_NAME="${KEY_NAME:-mern-ec2-key}"
KEY_PATH="${KEY_PATH:-$HOME/.ssh/${KEY_NAME}.pem}"
SG_NAME="${SG_NAME:-mern-app-sg}"
INSTANCE_NAME="${INSTANCE_NAME:-mern-app-server}"
OUTPUT_FILE="${OUTPUT_FILE:-}"
EIP_ALLOCATION_ID="${EIP_ALLOCATION_ID:-}"    # optional: also release a specific Elastic IP

EIP_ALLOCATION_IDS=""   # global: populated by find_eips()

ASSUME_YES="${ASSUME_YES:-false}"
DRY_RUN="${DRY_RUN:-false}"
DELETE_KEY_FILE="${DELETE_KEY_FILE:-false}"

INSTANCE_IDS=""   # global: populated by find_instances() before confirmation

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: ./destroy.sh [options]

Tears down the AWS resources created by deploy.sh (idempotent & safe).

Options:
  -y, --yes            Skip the confirmation prompt (automatic in CI)
  --dry-run            Show what would be deleted without deleting anything
  --delete-key-file    Also remove the local PEM at $KEY_PATH
  --help               Show this help

Environment variables (must match deploy.sh's values):
  AWS_REGION           AWS region                 (us-east-1)
  INSTANCE_NAME        Instance Name tag to terminate (mern-app-server)
  KEY_NAME             EC2 key pair to delete     (mern-ec2-key)
  KEY_PATH             Local PEM path             (~/.ssh/mern-ec2-key.pem)
  SG_NAME              Security group to delete   (mern-app-sg)
  OUTPUT_FILE          Append results to file (e.g. $GITHUB_OUTPUT)
  EIP_ALLOCATION_ID    Also release this specific Elastic IP allocation
EOF
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  command -v aws >/dev/null || die "aws CLI not found"
  export AWS_DEFAULT_REGION="$AWS_REGION"
  export AWS_PAGER=""
  log "Checking AWS credentials (region: $AWS_REGION) ..."
  aws sts get-caller-identity --query Arn --output text >/dev/null 2>&1 \
    || die "AWS credentials invalid/expired. Run 'aws configure' or set the AWS_* env vars."
  log "AWS identity OK: $(aws sts get-caller-identity --query Arn --output text)"

  # EC2 permission probe — fail fast with a clear message instead of a cryptic
  # AWS error mid-teardown (some lab accounts revoke the entire EC2 API).
  local ec2_err
  if ! ec2_err="$(aws ec2 describe-regions --query 'Regions[0].RegionName' --output text 2>&1)"; then
    warn "AWS: ${ec2_err}"
    if grep -Eq 'explicit deny|UnauthorizedOperation|AccessDenied' <<< "$ec2_err"; then
      die "EC2 access is denied for this AWS account/role (authentication works, but the EC2 APIs are blocked) — this usually means the lab/account has revoked EC2 permissions (e.g. policy 'voc-cancel-cred'). destroy.sh cannot manage EC2 resources with these credentials. Restore the lab/account permissions or use an AWS account with EC2 access."
    else
      die "The EC2 API probe failed unexpectedly. See the AWS error above; retry (transient network/API issues) or check the AWS configuration."
    fi
  fi
  log "EC2 access OK."
}

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
confirm() {
  if [[ "$ASSUME_YES" == "true" || "${CI:-}" == "true" ]]; then
    return 0
  fi
  echo
  local ans
  if ! read -r -p "[destroy] This will permanently DELETE the resources listed above. Type 'yes' to continue: " ans; then
    die "No input received — aborting."
  fi
  [[ "$ans" == "yes" ]] || die "Aborted by user."
}

# ---------------------------------------------------------------------------
# 1) Find instances tagged $INSTANCE_NAME (runs BEFORE confirmation so the
#    user sees the exact instance IDs; dies on AWS errors instead of treating
#    them as "nothing to delete")
# ---------------------------------------------------------------------------
find_instances() {
  local rc
  rc=0
  INSTANCE_IDS="$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
    --query 'Reservations[].Instances[].[InstanceId,PublicIpAddress]' --output text 2>/dev/null)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    die "Failed to query instances tagged '$INSTANCE_NAME' (AWS error) — aborting so nothing is deleted blindly. Retry."
  fi
  if [[ -z "$INSTANCE_IDS" ]]; then
    log "No running/stopped instances tagged '$INSTANCE_NAME' — nothing to terminate."
  else
    log "Found instances to terminate:"
    echo "$INSTANCE_IDS" | while read -r id ip; do
      [[ -z "$id" ]] && continue
      log "  • $id  (public IP: ${ip:-none})"
    done || true
  fi
}

destroy_instances() {
  local id
  while read -r id _; do
    [[ -z "$id" ]] && continue
    terminate_instance "$id"
  done <<< "$INSTANCE_IDS"
}

terminate_instance() {
  local id="$1" state
  log "Terminating instance $id ..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log "  (dry-run) would terminate $id"
    return 0
  fi
  if ! aws ec2 terminate-instances --instance-ids "$id" >/dev/null 2>&1; then
    warn "Could not terminate $id (already gone?) — continuing teardown."
    return 0
  fi

  local i
  for i in $(seq 1 24); do
    state="$(aws ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || true)"
    if [[ "$state" == "terminated" ]]; then
      log "Instance $id terminated."
      return 0
    fi
    sleep 10
  done
  warn "Instance $id has not reached 'terminated' yet (state: ${state:-unknown}) — it should finish shortly."
}

# ---------------------------------------------------------------------------
# 1b) Find Elastic IPs to release (runs BEFORE confirmation so the user sees
#     them). Covers: EIPs associated with the instances being terminated, EIPs
#     tagged $INSTANCE_NAME (both created by deploy.sh), and an explicit
#     EIP_ALLOCATION_ID.
# ---------------------------------------------------------------------------
find_eips() {
  local ids="" tagged="" joined=""
  if [[ -n "$INSTANCE_IDS" ]]; then
    joined="$(echo "$INSTANCE_IDS" | awk 'NF{print $1}' | tr '\n' ',' | sed 's/,$//')"
    ids="$(aws ec2 describe-addresses --filters "Name=instance-id,Values=${joined}" "Name=domain,Values=vpc" \
        --query 'Addresses[].AllocationId' --output text 2>/dev/null || true)"
  fi
  tagged="$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=${INSTANCE_NAME}" "Name=domain,Values=vpc" \
      --query 'Addresses[].AllocationId' --output text 2>/dev/null || true)"
  EIP_ALLOCATION_IDS="$(printf '%s\n%s\n%s\n' "${ids:-}" "${tagged:-}" "${EIP_ALLOCATION_ID:-}" | awk 'NF' | sort -u)"
  if [[ -n "$EIP_ALLOCATION_IDS" ]]; then
    log "Elastic IPs to release:"
    while read -r a; do
      [[ -n "$a" ]] && log "  • $a"
    done <<< "$EIP_ALLOCATION_IDS"
  else
    log "No Elastic IPs to release."
  fi
}

destroy_eips() {
  local a
  while read -r a; do
    [[ -z "$a" ]] && continue
    log "Releasing Elastic IP $a ..."
    if [[ "$DRY_RUN" == "true" ]]; then
      log "  (dry-run) would disassociate & release $a"
      continue
    fi
    aws ec2 disassociate-address --allocation-id "$a" >/dev/null 2>&1 || true
    if aws ec2 release-address --allocation-id "$a" >/dev/null 2>&1; then
      log "Elastic IP $a released."
    else
      warn "Could not release Elastic IP $a (already released or still in use?)."
    fi
  done <<< "$EIP_ALLOCATION_IDS"
}

# ---------------------------------------------------------------------------
# 2) Delete the key pair (and optionally the local PEM)
# ---------------------------------------------------------------------------
destroy_key_pair() {
  if aws ec2 describe-key-pairs --key-names "$KEY_NAME" --query 'KeyPairs[0].KeyName' --output text >/dev/null 2>&1; then
    # Safety: never silently break SSH for instances that are NOT being torn down
    local others rc ans
    rc=0
    others="$(aws ec2 describe-instances \
      --filters "Name=key-name,Values=${KEY_NAME}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)" || rc=$?
    if [[ $rc -eq 0 && -n "$others" && "$others" != "None" ]]; then
      warn "Key pair '$KEY_NAME' is still attached to other instances: $(echo "$others" | tr '\n' ' ') — deleting it would break SSH to them."
      if [[ "$ASSUME_YES" != "true" && "${CI:-}" != "true" ]]; then
        if ! read -r -p "[destroy] Delete the key pair anyway? Type 'yes': " ans; then
          die "No input received — aborting."
        fi
        if [[ "$ans" != "yes" ]]; then
          log "Skipping key pair '$KEY_NAME' deletion."
          return 0
        fi
      fi
    fi
    log "Deleting key pair '$KEY_NAME' ..."
    if [[ "$DRY_RUN" == "true" ]]; then
      log "  (dry-run) would delete key pair '$KEY_NAME'"
    else
      aws ec2 delete-key-pair --key-name "$KEY_NAME" >/dev/null
      log "Key pair '$KEY_NAME' deleted."
    fi
  else
    log "Key pair '$KEY_NAME' not found on AWS — nothing to do."
  fi

  if [[ -f "$KEY_PATH" ]]; then
    if [[ "$DELETE_KEY_FILE" == "true" ]]; then
      log "Removing local PEM $KEY_PATH ..."
      if [[ "$DRY_RUN" != "true" ]]; then
        rm -f "$KEY_PATH"
        log "Local PEM removed."
      else
        log "  (dry-run) would remove local PEM $KEY_PATH"
      fi
    else
      log "Keeping local PEM $KEY_PATH (pass --delete-key-file to remove it)."
    fi
  fi
}

# ---------------------------------------------------------------------------
# 3) Delete the security group (retry briefly — the instance may still be
#    releasing its network interfaces)
# ---------------------------------------------------------------------------
destroy_security_group() {
  local vpc_id sg_id i
  vpc_id="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"
  sg_id="$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=group-name,Values=${SG_NAME}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
  if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
    log "Security group '$SG_NAME' not found — nothing to do."
    return 0
  fi

  log "Deleting security group '$SG_NAME' ($sg_id) ..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log "  (dry-run) would delete security group '$SG_NAME' ($sg_id)"
    return 0
  fi

  for i in $(seq 1 6); do
    if aws ec2 delete-security-group --group-id "$sg_id" >/dev/null 2>&1; then
      log "Security group '$SG_NAME' ($sg_id) deleted."
      return 0
    fi
    sleep 10
  done
  warn "Could not delete security group '$SG_NAME' ($sg_id) — it may still be referenced by another resource (e.g. an instance or load balancer)."
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
write_output() {
  echo "$1"
  if [[ -n "$OUTPUT_FILE" ]]; then
    echo "$1" >> "$OUTPUT_FILE"
  fi
}

summary() {
  echo
  log "======================== TEARDOWN COMPLETE ========================"
  write_output "teardown_instance_name=$INSTANCE_NAME"
  if [[ -n "$EIP_ALLOCATION_IDS" ]]; then
    write_output "teardown_elastic_ips=$(echo "$EIP_ALLOCATION_IDS" | tr '\n' ' ')"
  fi
  write_output "teardown_key_name=$KEY_NAME"
  write_output "teardown_security_group=$SG_NAME"
  if [[ "$DRY_RUN" == "true" ]]; then
    log " (dry-run — nothing was actually deleted)"
  fi
  log "================================================================"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -y|--yes)           ASSUME_YES="true" ;;
      --dry-run)          DRY_RUN="true" ;;
      --delete-key-file)  DELETE_KEY_FILE="true" ;;
      --help|-h)          usage; exit 0 ;;
      *)                  die "Unknown option: $arg (see --help)" ;;
    esac
  done

  preflight

  echo
  log "Targeting the following AWS resources in $AWS_REGION:"
  log "  • Instances tagged Name=$INSTANCE_NAME"
  log "  • Elastic IPs tagged Name=$INSTANCE_NAME (and EIP_ALLOCATION_ID)"
  log "  • Key pair $KEY_NAME"
  log "  • Security group $SG_NAME"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "Running in DRY-RUN mode — nothing will be deleted."
  fi

  # Resolve and show the exact instance IDs and Elastic IPs BEFORE asking
  # for confirmation
  find_instances
  find_eips
  confirm

  destroy_instances
  destroy_eips
  destroy_key_pair
  destroy_security_group
  summary
}

main "$@"
