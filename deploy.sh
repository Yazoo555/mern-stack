#!/usr/bin/env bash
# =============================================================================
# deploy.sh — One-command, idempotent deployment of the MERN Expense Tracker
#             to AWS EC2 (Amazon Linux 2023) using Docker Hub images.
#
#   What it does:
#     1. Builds the backend & frontend Docker images and pushes them to Docker Hub
#     2. Ensures an EC2 key pair exists (creates + saves the PEM if missing)
#     3. Ensures a security group exists with ports 22 / 5000 / 5173 open
#     4. Reuses an instance tagged $INSTANCE_NAME — running → use it, stopped →
#        start it (no duplicate launches); only launches a new one if none exists
#     5. Ensures an Elastic IP is allocated & associated with the instance, so
#        the public IP never changes across stop/start (reuses the EIP tagged
#        with $INSTANCE_NAME, or the one in EIP_ALLOCATION_ID)
#     6. Provisions Docker + Docker Compose on the instance (idempotent)
#     7. Generates docker-compose.yml (with the Elastic IP baked into
#        VITE_API_URL) and deploys mongodb / backend / frontend
#     8. Verifies health end-to-end and prints the public URLs
#
#   CI/CD ready (GitHub Actions):
#     • All configuration via environment variables — no hardcoded secrets
#     • DOCKER_HUB_TOKEN  → performs `docker login` automatically when set
#     • OUTPUT_FILE       → appends machine-readable results (instance_id,
#                           ec2_public_ip, elastic_ip, eip_allocation_id,
#                           frontend_url, backend_url) e.g.
#                           set OUTPUT_FILE=$GITHUB_OUTPUT in a workflow
#     • Exit code 0 on success, non-zero on failure (CI-friendly)
#     • --build-only / --deploy-only allow splitting CI jobs
#
#   Usage:
#     ./deploy.sh [--build-only] [--deploy-only] [--skip-build] [--skip-push] [--help]
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Logging helpers (colors auto-disabled in CI / non-TTY)
# ---------------------------------------------------------------------------
if [[ -t 1 && "${CI:-}" != "true" ]]; then
  C_BOLD=$'\e[1m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_RESET=$'\e[0m'
else
  C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi
log()  { echo -e "${C_BOLD}${C_GREEN}[deploy]${C_RESET} $*"; }
warn() { echo -e "${C_BOLD}${C_YELLOW}[deploy] WARN:${C_RESET} $*" >&2; }
die()  { echo -e "${C_BOLD}${C_RED}[deploy] ERROR:${C_RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Configuration (everything can be overridden via environment variables)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$SCRIPT_DIR}"

# Docker Hub
DOCKER_HUB_USER="${DOCKER_HUB_USER:-yazoo555}"
DOCKER_HUB_TOKEN="${DOCKER_HUB_TOKEN:-}"                      # optional → auto login
DOCKER_HUB_REPO="${DOCKER_HUB_REPO:-yazoo555/docker-recepie}"
BACKEND_IMAGE="${BACKEND_IMAGE:-${DOCKER_HUB_REPO}:backend}"
FRONTEND_IMAGE="${FRONTEND_IMAGE:-${DOCKER_HUB_REPO}:frontend}"
PUSH_IMAGES="${PUSH_IMAGES:-true}"                            # push after build
SKIP_BUILD="${SKIP_BUILD:-false}"                             # reuse existing local images

# AWS
AWS_REGION="${AWS_REGION:-us-east-1}"
KEY_NAME="${KEY_NAME:-mern-ec2-key}"
KEY_PATH="${KEY_PATH:-$HOME/.ssh/${KEY_NAME}.pem}"
SG_NAME="${SG_NAME:-mern-app-sg}"
INSTANCE_NAME="${INSTANCE_NAME:-mern-app-server}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t2.micro}"
AMI_ID="${AMI_ID:-auto}"                                      # "auto" = latest AL2023
SSH_CIDR="${SSH_CIDR:-0.0.0.0/0}"                             # who may SSH in
EC2_USER="${EC2_USER:-ec2-user}"
APP_DIR="${APP_DIR:-app}"                                     # dir on the instance

# App
COMPOSE_SRC="${COMPOSE_SRC:-$PROJECT_ROOT/docker-compose.prod.yml}"
API_PORT="${API_PORT:-5000}"
FRONTEND_PORT="${FRONTEND_PORT:-5173}"

OUTPUT_FILE="${OUTPUT_FILE:-}"                                # e.g. $GITHUB_OUTPUT
EIP_ALLOCATION_ID="${EIP_ALLOCATION_ID:-}"                    # optional: pin a specific Elastic IP

MODE="all"        # all | build-only | deploy-only
COMPOSE_TMP_FILE=""   # global so the EXIT trap can always reference it

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: ./deploy.sh [options]

Automated, idempotent deployment of the MERN Expense Tracker to AWS EC2.

Options:
  --build-only    Build & push Docker images only (no AWS work)
  --deploy-only   Deploy to EC2 only (images must already be on Docker Hub)
  --skip-build    Skip the docker build; push the existing local images
  --skip-push     Build images locally but do not push to Docker Hub
  --help          Show this help

Environment variables (all optional, defaults shown):
  DOCKER_HUB_USER    Docker Hub username                (yazoo555)
  DOCKER_HUB_TOKEN   Docker Hub access token            (auto `docker login` if set)
  DOCKER_HUB_REPO    Docker Hub repository              (yazoo555/docker-recepie)
  PUSH_IMAGES        true/false — push after build      (true)
  AWS_REGION         AWS region                         (us-east-1)
  KEY_NAME           EC2 key pair name                  (mern-ec2-key)
  KEY_PATH           Local path for the key PEM         (~/.ssh/mern-ec2-key.pem)
  SG_NAME            Security group name                (mern-app-sg)
  INSTANCE_NAME      Instance Name tag (running/stopped are reused) (mern-app-server)
  INSTANCE_TYPE      EC2 instance type                  (t2.micro)
  AMI_ID             AMI id, or "auto" for latest AL2023 (auto)
  SSH_CIDR           CIDR allowed for SSH               (0.0.0.0/0)
  EC2_USER           SSH user                           (ec2-user)
  EIP_ALLOCATION_ID  Allocation ID of a specific Elastic IP to use — otherwise
                     the EIP tagged with INSTANCE_NAME is reused, or a fresh
                     one is allocated                 (auto)
  OUTPUT_FILE        File to append results to (e.g. $GITHUB_OUTPUT)

Examples:
  ./deploy.sh                                   # full pipeline
  ./deploy.sh --build-only                      # images only (CI job 1)
  ./deploy.sh --deploy-only                     # deploy only (CI job 2)
EOF
}

# ---------------------------------------------------------------------------
# Preflight: local tools + Docker Hub auth + AWS credentials
# ---------------------------------------------------------------------------
preflight() {
  log "Preflight checks..."
  command -v docker >/dev/null || die "docker CLI not found"
  command -v aws    >/dev/null || die "aws CLI not found"
  command -v ssh    >/dev/null || die "ssh not found"
  command -v scp    >/dev/null || die "scp not found"
  command -v curl   >/dev/null || die "curl not found"
  docker info >/dev/null 2>&1 || die "Docker daemon is not running (docker info failed). Start Docker and retry."

  # Docker Hub auth
  if [[ -n "$DOCKER_HUB_TOKEN" ]]; then
    log "Logging in to Docker Hub as '${DOCKER_HUB_USER}' ..."
    echo "$DOCKER_HUB_TOKEN" | docker login -u "$DOCKER_HUB_USER" --password-stdin >/dev/null 2>&1 \
      || die "docker login failed — check DOCKER_HUB_USER / DOCKER_HUB_TOKEN"
  else
    local user
    user="$(docker system info 2>/dev/null | awk -F': ' '/^ Username:/{print $2}')"
    if [[ -z "$user" ]]; then
      die "Not logged in to Docker Hub. Run 'docker login' or set DOCKER_HUB_TOKEN."
    fi
    log "Docker Hub: already logged in as '$user'."
    if [[ "$user" != "$DOCKER_HUB_USER" ]]; then
      if [[ "$PUSH_IMAGES" == "true" ]]; then
        die "Logged in as '$user' but DOCKER_HUB_USER='$DOCKER_HUB_USER' with PUSH_IMAGES=true — the push would fail. Fix the Docker Hub login or DOCKER_HUB_USER."
      else
        warn "Logged in as '$user' but DOCKER_HUB_USER='$DOCKER_HUB_USER'."
      fi
    fi
  fi

  # AWS credentials
  export AWS_DEFAULT_REGION="$AWS_REGION"
  export AWS_PAGER=""
  log "Checking AWS credentials (region: $AWS_REGION) ..."
  aws sts get-caller-identity --query Arn --output text >/dev/null 2>&1 \
    || die "AWS credentials invalid/expired. Run './set-aws-creds.sh' to paste fresh lab credentials, or set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (and AWS_SESSION_TOKEN for temp creds)."
  log "AWS identity OK: $(aws sts get-caller-identity --query Arn --output text)"

  # EC2 permission probe — fail fast with a clear, actionable message instead of a
  # cryptic AWS error later in the deploy. Some lab accounts (e.g. VOC Labs)
  # attach an explicit-deny policy (voc-cancel-cred) that blocks the ENTIRE EC2
  # API even though authentication (sts) still works.
  # Skipped in --build-only mode, which never touches EC2.
  if [[ "$MODE" != "build-only" ]]; then
    local ec2_err
    if ! ec2_err="$(aws ec2 describe-regions --query 'Regions[0].RegionName' --output text 2>&1)"; then
      warn "AWS: ${ec2_err}"
      if grep -Eq 'explicit deny|UnauthorizedOperation|AccessDenied' <<< "$ec2_err"; then
        die "EC2 access is denied for this AWS account/role (authentication works, but the EC2 APIs are blocked) — this usually means the lab/account has revoked EC2 permissions (e.g. policy 'voc-cancel-cred'). deploy.sh cannot deploy to EC2 with these credentials. Restart/restore the lab (or contact its provider/instructor) or use an AWS account that has EC2 access."
      else
        die "The EC2 API probe failed unexpectedly. See the AWS error above; retry (transient network/API issues) or check the AWS configuration."
      fi
    fi
    log "EC2 access OK."
  fi
}

# ---------------------------------------------------------------------------
# Step 1 — build & push images
# ---------------------------------------------------------------------------
build_and_push() {
  log "Building backend image  → ${BACKEND_IMAGE}"
  ( cd "$PROJECT_ROOT/backend" && docker build -t "$BACKEND_IMAGE" . )
  log "Building frontend image → ${FRONTEND_IMAGE}"
  ( cd "$PROJECT_ROOT/frontend" && docker build -t "$FRONTEND_IMAGE" . )

  if [[ "$PUSH_IMAGES" == "true" ]]; then
    log "Pushing ${BACKEND_IMAGE} ..."
    docker push "$BACKEND_IMAGE"
    log "Pushing ${FRONTEND_IMAGE} ..."
    docker push "$FRONTEND_IMAGE"
  else
    log "Skipping push (PUSH_IMAGES != true)."
  fi
}

# ---------------------------------------------------------------------------
# Step 2 — EC2 key pair (reuse or create)
# ---------------------------------------------------------------------------
ensure_key_pair() {
  if aws ec2 describe-key-pairs --key-names "$KEY_NAME" --query 'KeyPairs[0].KeyName' --output text >/dev/null 2>&1; then
    log "Key pair '$KEY_NAME' already exists on AWS."
    if [[ ! -s "$KEY_PATH" ]]; then
      die "Key pair '$KEY_NAME' exists on AWS but no non-empty PEM found at $KEY_PATH. Provide the PEM file or delete the key pair and re-run."
    fi
  else
    log "Creating key pair '$KEY_NAME' ..."
    mkdir -p "$(dirname "$KEY_PATH")"
    local tmp err
    tmp="$(mktemp)"
    # Write to a temp file first so a failed AWS call can never leave a broken
    # (0-byte) PEM behind at $KEY_PATH.
    if ! err="$(aws ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > "$tmp" 2>&1)"; then
      rm -f "$tmp"
      warn "AWS: ${err:-unknown error}"
      die "Failed to create key pair '$KEY_NAME'. If AWS reports an explicit deny (e.g. from policy 'voc-cancel-cred'), your lab/account has revoked ec2:CreateKeyPair — deploy.sh cannot deploy to EC2 with these credentials. Restore the lab permissions or use an AWS account with EC2 access."
    fi
    if [[ ! -s "$tmp" ]]; then
      rm -f "$tmp"
      die "AWS returned an empty key pair for '$KEY_NAME' — aborting so no broken PEM is left behind."
    fi
    mv "$tmp" "$KEY_PATH"
    chmod 600 "$KEY_PATH"
    log "Saved private key to $KEY_PATH"
  fi
}

# ---------------------------------------------------------------------------
# Step 3 — security group (reuse or create) + idempotent ingress rules
# ---------------------------------------------------------------------------
ensure_security_group() {
  local vpc_id sg_id
  vpc_id="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
  [[ -n "$vpc_id" && "$vpc_id" != "None" ]] || die "No default VPC found in region $AWS_REGION"
  sg_id="$(aws ec2 describe-security-groups \
      --filters "Name=vpc-id,Values=$vpc_id" "Name=group-name,Values=$SG_NAME" \
      --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
  if [[ -n "$sg_id" && "$sg_id" != "None" ]]; then
    log "Security group '$SG_NAME' already exists ($sg_id)."
  else
    log "Creating security group '$SG_NAME' ..."
    sg_id="$(aws ec2 create-security-group --group-name "$SG_NAME" \
        --description "MERN deployment: SSH/API/Frontend" --vpc-id "$vpc_id" --query 'GroupId' --output text)"
    log "Created $sg_id"
  fi
  SG_ID="$sg_id"
  ensure_sg_rule 22            "SSH"
  ensure_sg_rule "$API_PORT"   "Backend API"
  ensure_sg_rule "$FRONTEND_PORT" "Frontend"
}

ensure_sg_rule() {
  local port="$1" desc="$2" existing
  existing="$(aws ec2 describe-security-groups --group-ids "$SG_ID" \
      --query "SecurityGroups[0].IpPermissions[?FromPort==\`${port}\`].IpRanges[].CidrIp" --output text 2>/dev/null || true)"
  if grep -qw "$SSH_CIDR" <<<"$existing"; then
    log "  port ${port}/tcp rule already present."
  else
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
      --ip-permissions "IpProtocol=tcp,FromPort=${port},ToPort=${port},IpRanges=[{CidrIp=${SSH_CIDR},Description=${desc}}]" >/dev/null
    log "  added ingress rule: ${port}/tcp from ${SSH_CIDR} (${desc})"
  fi
}

# ---------------------------------------------------------------------------
# Step 4 — AMI resolution + instance (reuse by tag or launch)
# ---------------------------------------------------------------------------
resolve_ami() {
  if [[ "$AMI_ID" == "auto" ]]; then
    AMI_ID="$(aws ec2 describe-images --owners amazon \
      --filters 'Name=name,Values=al2023-ami-2023.*-x86_64' 'Name=state,Values=available' \
      --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)"
  fi
  log "Using AMI: $AMI_ID"
}

aws_wait_state() {
  local id="$1" want="$2" i state
  log "Waiting for instance $id to reach state '$want' ..."
  for i in $(seq 1 60); do
    state="$(aws ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].State.Name' --output text)"
    if [[ "$state" == "$want" ]]; then
      return 0
    fi
    sleep 10
  done
  die "Instance $id did not reach state '$want' in time (last: ${state:-unknown})"
}

ensure_instance() {
  resolve_ami
  local rc found n id state
  rc=0
  # Match ANY non-terminated instance tagged $INSTANCE_NAME — a stopped instance
  # is started and reused instead of launching a duplicate.
  found="$(aws ec2 describe-instances \
      --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
                "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text 2>/dev/null)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    die "Failed to query instances tagged '$INSTANCE_NAME' (AWS error) — refusing to launch blindly. Retry."
  fi
  n=0
  while read -r id state; do
    [[ -z "$id" ]] && continue
    n=$((n + 1))
  done <<< "$found"
  if [[ "$n" -gt 1 ]]; then
    die "Multiple instances are tagged '$INSTANCE_NAME' (states: $(echo "$found" | tr '\n' ' ')). Stop/terminate all but one (or set INSTANCE_NAME to a unique tag) and re-run."
  elif [[ "$n" -eq 1 ]]; then
    INSTANCE_ID="$(echo "$found" | awk 'NF{print $1; exit}')"
    state="$(echo "$found" | awk 'NF{print $2; exit}')"
    case "$state" in
      running)
        log "Reusing running instance '$INSTANCE_NAME' → $INSTANCE_ID" ;;
      pending)
        log "Instance '$INSTANCE_NAME' ($INSTANCE_ID) is still pending — waiting for it to start ..."
        aws_wait_state "$INSTANCE_ID" running ;;
      stopping)
        log "Instance '$INSTANCE_NAME' ($INSTANCE_ID) is stopping — waiting for it to stop, then starting it ..."
        aws_wait_state "$INSTANCE_ID" stopped
        log "Starting stopped instance '$INSTANCE_NAME' → $INSTANCE_ID ..."
        aws ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
        aws_wait_state "$INSTANCE_ID" running ;;
      stopped)
        log "Starting stopped instance '$INSTANCE_NAME' → $INSTANCE_ID ..."
        aws ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
        aws_wait_state "$INSTANCE_ID" running ;;
      *)
        die "Instance '$INSTANCE_NAME' ($INSTANCE_ID) is in unexpected state '$state' — aborting. Wait for it to settle and re-run." ;;
    esac
  else
    local subnet
    subnet="$(aws ec2 describe-subnets --filters Name=defaultForAz,Values=true --query 'Subnets[0].SubnetId' --output text)"
    log "Launching new instance '$INSTANCE_NAME' ($INSTANCE_TYPE) ..."
    INSTANCE_ID="$(aws ec2 run-instances \
      --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
      --key-name "$KEY_NAME" --security-group-ids "$SG_ID" \
      --subnet-id "$subnet" --associate-public-ip-address \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
      --query 'Instances[0].InstanceId' --output text)"
    aws_wait_state "$INSTANCE_ID" running
  fi
  log "Instance ready: $INSTANCE_ID"
}

# ---------------------------------------------------------------------------
# Step 5 — Elastic IP (stable public IP across stop/start)
# ---------------------------------------------------------------------------
ensure_elastic_ip() {
  log "Ensuring a stable Elastic IP for $INSTANCE_ID ..."
  local alloc_id="" assoc i ip

  # 1) Explicitly pinned EIP (set EIP_ALLOCATION_ID to use a specific one)
  if [[ -n "$EIP_ALLOCATION_ID" ]]; then
    log "Using Elastic IP from EIP_ALLOCATION_ID=$EIP_ALLOCATION_ID"
    aws ec2 describe-addresses --allocation-ids "$EIP_ALLOCATION_ID" \
        --query 'Addresses[0].AllocationId' --output text >/dev/null 2>&1 \
      || die "EIP_ALLOCATION_ID '$EIP_ALLOCATION_ID' was not found in region $AWS_REGION."
    alloc_id="$EIP_ALLOCATION_ID"
  else
    # 2) An EIP already associated with this instance (survives stop/start)
    alloc_id="$(aws ec2 describe-addresses \
        --filters "Name=instance-id,Values=${INSTANCE_ID}" "Name=domain,Values=vpc" \
        --query 'Addresses[0].AllocationId' --output text 2>/dev/null || true)"
    [[ "$alloc_id" == "None" ]] && alloc_id=""
    if [[ -n "$alloc_id" ]]; then
      log "Instance already has Elastic IP $alloc_id — reusing it."
    else
      # 3) An EIP tagged $INSTANCE_NAME from a previous deploy — this keeps the
      #    SAME public IP across re-deploys
      local tagged first="" cnt=0
      tagged="$(aws ec2 describe-addresses \
          --filters "Name=tag:Name,Values=${INSTANCE_NAME}" "Name=domain,Values=vpc" \
          --query 'Addresses[].[AllocationId,InstanceId]' --output text 2>/dev/null || true)"
      while read -r a _; do
        [[ -z "$a" ]] && continue
        cnt=$((cnt + 1)); [[ -z "$first" ]] && first="$a"
      done <<< "$tagged"
      if [[ "$cnt" -gt 1 ]]; then
        die "Multiple Elastic IPs are tagged '$INSTANCE_NAME' ($cnt). Keep only one, or release the extras with: aws ec2 release-address --allocation-id <id>"
      elif [[ "$cnt" -eq 1 ]]; then
        alloc_id="$first"
        log "Reusing Elastic IP $alloc_id from a previous deploy."
      fi
    fi
  fi

  # 4) Nothing reusable → allocate a fresh Elastic IP
  if [[ -z "$alloc_id" ]]; then
    log "Allocating a new Elastic IP (tagged '$INSTANCE_NAME') ..."
    if ! alloc_id="$(aws ec2 allocate-address --domain vpc \
        --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
        --query 'AllocationId' --output text 2>&1)"; then
      die "Failed to allocate an Elastic IP (AWS: ${alloc_id}). This usually means the account lacks ec2:AllocateAddress, or the EIP limit (5 per region) is exhausted — free one with: aws ec2 release-address --allocation-id <id>"
    fi
  fi
  EIP_ALLOCATION_ID="$alloc_id"

  # 5) Associate with the instance (idempotent)
  assoc="$(aws ec2 describe-addresses --allocation-ids "$EIP_ALLOCATION_ID" \
      --query 'Addresses[0].InstanceId' --output text 2>/dev/null || true)"
  if [[ "$assoc" == "$INSTANCE_ID" ]]; then
    log "Elastic IP already associated with $INSTANCE_ID."
  else
    if [[ -n "$assoc" && "$assoc" != "None" ]]; then
      log "Disassociating Elastic IP from instance $assoc ..."
      aws ec2 disassociate-address --allocation-id "$EIP_ALLOCATION_ID" >/dev/null \
        || die "Failed to disassociate the Elastic IP from $assoc — check the ec2:DisassociateAddress permission and retry."
    fi
    log "Associating Elastic IP with $INSTANCE_ID ..."
    aws ec2 associate-address --allocation-id "$EIP_ALLOCATION_ID" \
        --instance-id "$INSTANCE_ID" >/dev/null \
      || die "Failed to associate the Elastic IP with $INSTANCE_ID — the instance must be running and the account needs the ec2:AssociateAddress permission."
  fi

  # 6) From here on the stable IP is the Elastic IP (SSH, VITE_API_URL, URLs)
  PUBLIC_IP="$(aws ec2 describe-addresses --allocation-ids "$EIP_ALLOCATION_ID" \
      --query 'Addresses[0].PublicIp' --output text)"
  for i in $(seq 1 24); do
    ip="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
    [[ "$ip" == "$PUBLIC_IP" ]] && break
    sleep 5
  done
  [[ "$ip" == "$PUBLIC_IP" ]] \
    || die "Elastic IP $PUBLIC_IP did not attach to $INSTANCE_ID in time (instance reports ${ip:-none}). Inspect with: aws ec2 describe-addresses --allocation-ids $EIP_ALLOCATION_ID"
  log "Elastic IP: $PUBLIC_IP (allocation $EIP_ALLOCATION_ID) — stable across stop/start"
}

# ---------------------------------------------------------------------------
# Step 6 — SSH helpers + provisioning
# ---------------------------------------------------------------------------
ssh_cmd() { ssh "${SSH_OPTS[@]}" "${EC2_USER}@${PUBLIC_IP}" "$@"; }
scp_cmd() { scp "${SSH_OPTS[@]}" "$@"; }

wait_ssh() {
  log "Waiting for SSH on ${PUBLIC_IP} ..."
  local i
  for i in $(seq 1 30); do
    if ssh_cmd 'true' >/dev/null 2>&1; then return 0; fi
    sleep 10
  done
  die "SSH not reachable on ${PUBLIC_IP} (check the instance and security group)"
}

provision() {
  log "Provisioning Docker + Compose on the instance ..."
  ssh_cmd 'command -v docker >/dev/null 2>&1 || sudo dnf install -y docker >/dev/null 2>&1'
  ssh_cmd 'sudo systemctl enable --now docker >/dev/null 2>&1 || true'
  ssh_cmd "sudo usermod -aG docker '$EC2_USER' 2>/dev/null || true"
  ssh_cmd 'docker compose version >/dev/null 2>&1 || (sudo mkdir -p /usr/local/lib/docker/cli-plugins && sudo curl -sSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose && sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose)'
  log "docker : $(ssh_cmd 'docker --version')"
  log "compose: $(ssh_cmd 'docker compose version')"
}

# ---------------------------------------------------------------------------
# Step 7 — generate compose file (bake in the Elastic IP) and deploy
# ---------------------------------------------------------------------------
deploy_compose() {
  [[ -f "$COMPOSE_SRC" ]] || die "Compose template not found: $COMPOSE_SRC (set COMPOSE_SRC or run from the repo root)"
  COMPOSE_TMP_FILE="$(mktemp)"
  trap '[[ -n "${COMPOSE_TMP_FILE:-}" ]] && rm -f "$COMPOSE_TMP_FILE"' EXIT

  log "Generating docker-compose.yml (VITE_API_URL → http://${PUBLIC_IP}:${API_PORT}) ..."
  sed -e "s|- VITE_API_URL=.*|- VITE_API_URL=http://${PUBLIC_IP}:${API_PORT}|" "$COMPOSE_SRC" > "$COMPOSE_TMP_FILE"
  docker compose -f "$COMPOSE_TMP_FILE" config -q >/dev/null 2>&1 \
    || die "Generated docker-compose.yml failed validation — check COMPOSE_SRC ($COMPOSE_SRC)"

  ssh_cmd "mkdir -p ~/${APP_DIR}"
  scp_cmd "$COMPOSE_TMP_FILE" "${EC2_USER}@${PUBLIC_IP}:~/${APP_DIR}/docker-compose.yml"

  log "Pulling latest images on the instance (this can take a few minutes) ..."
  ssh_cmd "cd ~/${APP_DIR} && sudo docker compose pull"

  log "Starting services ..."
  ssh_cmd "cd ~/${APP_DIR} && sudo docker compose up -d"
}

# ---------------------------------------------------------------------------
# Step 8 — health verification
# ---------------------------------------------------------------------------
wait_health() {
  log "Waiting for services to become healthy ..."
  local i api fe
  for i in $(seq 1 30); do
    api="$(ssh_cmd "curl -s -o /dev/null -w '%{http_code}' http://localhost:${API_PORT}/api/expenses" 2>/dev/null || echo 000)"
    fe="$(ssh_cmd "curl -s -o /dev/null -w '%{http_code}' http://localhost:${FRONTEND_PORT}" 2>/dev/null || echo 000)"
    if [[ "$api" == "200" && "$fe" == "200" ]]; then
      log "Backend API and frontend both responding (HTTP 200)."
      local ps_out
      ps_out="$(ssh_cmd "cd ~/${APP_DIR} && sudo docker compose ps --format '{{.Service}}:{{.State}}' | tr '\n' ' '" 2>/dev/null || true)"
      log "Containers: $ps_out"
      return 0
    fi
    sleep 10
  done
  die "Health check failed (backend=${api} frontend=${fe}). Inspect with:
  ssh -i $KEY_PATH ${EC2_USER}@${PUBLIC_IP} 'cd ~/${APP_DIR} && sudo docker compose ps && sudo docker compose logs --tail 50'"
}

# ---------------------------------------------------------------------------
# Outputs (terminal + optional machine-readable file)
# ---------------------------------------------------------------------------
write_output() {
  echo "$1"
  if [[ -n "$OUTPUT_FILE" ]]; then
    echo "$1" >> "$OUTPUT_FILE"
  fi
}

summary() {
  echo
  log "======================== DEPLOYMENT COMPLETE ========================"
  write_output "instance_id=$INSTANCE_ID"
  write_output "ec2_public_ip=$PUBLIC_IP"
  write_output "elastic_ip=$PUBLIC_IP"
  write_output "eip_allocation_id=${EIP_ALLOCATION_ID:-}"
  write_output "frontend_url=http://${PUBLIC_IP}:${FRONTEND_PORT}"
  write_output "backend_url=http://${PUBLIC_IP}:${API_PORT}"
  echo
  echo -e "  ${C_BOLD}Frontend:${C_RESET} ${C_GREEN}http://${PUBLIC_IP}:${FRONTEND_PORT}${C_RESET}"
  echo -e "  ${C_BOLD}Backend :${C_RESET} ${C_GREEN}http://${PUBLIC_IP}:${API_PORT}/api/expenses${C_RESET}"
  echo -e "  ${C_BOLD}SSH     :${C_RESET} ${C_GREEN}ssh -i $KEY_PATH ${EC2_USER}@${PUBLIC_IP}${C_RESET}"
  log "====================================================================="
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --build-only)  MODE="build-only" ;;
      --deploy-only) MODE="deploy-only" ;;
      --skip-build)  SKIP_BUILD="true" ;;
      --skip-push)   PUSH_IMAGES="false" ;;
      --help|-h)     usage; exit 0 ;;
      *)             die "Unknown option: $arg (see --help)" ;;
    esac
  done

  preflight

  if [[ "$MODE" != "deploy-only" ]]; then
    if [[ "$SKIP_BUILD" == "true" ]]; then
      log "Skipping build (--skip-build); pushing existing local images ..."
      if [[ "$PUSH_IMAGES" == "true" ]]; then
        docker push "$BACKEND_IMAGE"
        docker push "$FRONTEND_IMAGE"
      fi
    else
      build_and_push
    fi
  fi

  if [[ "$MODE" != "build-only" ]]; then
    ensure_key_pair
    ensure_security_group
    ensure_instance
    ensure_elastic_ip
    SSH_OPTS=(-i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15)
    wait_ssh
    provision
    deploy_compose
    wait_health
    summary
  else
    log "build-only mode: done."
  fi
}

main "$@"
