# MERN Expense Tracker

A minimal full-stack expense tracking application built with the MERN stack (MongoDB, Express, React, Node.js). Add expenses with a description, amount, and category, see your totals at a glance, edit or delete entries, and filter by category — all through a dark, polished UI.

This project is designed as a **learning resource for Docker and Docker Compose**: each service (frontend, backend, database) runs in its own container, orchestrated by `docker-compose.yml`.

## Project Structure

```
/
├── backend/            # Node.js + Express API
│   ├── config/         # Database connection
│   ├── controllers/    # Request handlers
│   ├── models/         # Mongoose schema
│   ├── routes/         # Express routes
│   ├── server.js       # Entry point
│   └── Dockerfile
├── frontend/           # React + Vite
│   ├── src/
│   │   ├── App.jsx     # Main component
│   │   ├── App.css     # Styles
│   │   └── main.jsx    # React entry point
│   ├── index.html
│   └── Dockerfile
├── docker-compose.yml      # Orchestrates all 3 services (local dev)
├── docker-compose.prod.yml # Production compose template (Docker Hub images)
├── deploy.sh               # One-command automated deployment to AWS EC2
├── destroy.sh              # Safe teardown of the deployed AWS resources
├── set-aws-creds.sh        # Paste fresh AWS lab credentials (run after each lab start)
├── .github/
│   └── workflows/
│       └── deploy.yml      # GitHub Actions CI/CD workflow
└── README.md
```

## Prerequisites

- [Docker](https://www.docker.com/) and [Docker Compose](https://docs.docker.com/compose/) (the recommended way to run this app)
- Or [Node.js](https://nodejs.org/) (v18+) and [MongoDB](https://www.mongodb.com/) locally

## Running with Docker Compose (recommended)

From the project root:

```bash
docker compose up --build
```

This starts three containers:

| Container         | Service   | URL                       |
|-------------------|-----------|---------------------------|
| mongodb           | Database  | mongodb://localhost:27017 |
| mernbackendcon    | Backend   | http://localhost:5000     |
| mernfrontendcon   | Frontend  | http://localhost:5173     |

Open **http://localhost:5173** in your browser.

> **Note:** this repo also contains other MERN projects (`mern/`, `new-mern/`) whose containers use the same names and ports. If you have run one of them, stop it first (`docker compose down`) to avoid container-name and port conflicts.

Useful commands:

```bash
docker compose ps                 # check container status
docker compose logs -f backend    # follow backend logs
docker compose down               # stop containers (data persists in the volume)
docker compose down -v            # stop containers and delete the database volume
```

> **How the pieces talk to each other:** the backend connects to MongoDB using `MONGO_URI=mongodb://mongodb:27017/expense-tracker` — the hostname `mongodb` is the Docker *service name*, resolved automatically on the shared `mern-network`. The browser reaches the backend at `http://localhost:5000` (mapped through the host port).

## Running locally (without Docker)

### 1. Backend

```bash
cd backend
npm install
cp .env.example .env   # Update MONGO_URI with your MongoDB connection string
npm start              # Starts on http://localhost:5000
```

### 2. Frontend

```bash
cd frontend
npm install
cp .env.example .env   # VITE_API_URL defaults to http://localhost:5000
npm run dev            # Starts on http://localhost:5173
```

### 3. Open the app

Visit **http://localhost:5173** in your browser.

## Deploying to AWS EC2 (automated)

[`deploy.sh`](deploy.sh) runs the entire deployment to an Amazon Linux 2023 EC2 instance in one command — it is **idempotent** (safe to re-run) and **CI/CD-ready**. It reuses the existing key pair, security group, and EC2 instance (matched by the `INSTANCE_NAME` tag — a **stopped** instance is started and reused instead of launching a duplicate) and creates them from scratch if they have been deleted. It also attaches an **Elastic IP** so the public URL stays the same even after the instance is stopped and started again.

**What it does:**

1. **Preflight** — verifies `docker`, `aws`, `ssh`, `scp`, `curl` are installed, ensures Docker Hub login, validates AWS credentials, and probes EC2 access (fails fast with a clear message if the account blocks the EC2 API — e.g. a revoked/expired lab).
2. **Build & push** — builds `yazoo555/docker-recepie:backend` and `:frontend` and pushes them to Docker Hub.
3. **Key pair** — reuses `mern-ec2-key` if it exists, otherwise creates it and saves the PEM locally (`~/.ssh/mern-ec2-key.pem`).
4. **Security group** — reuses `mern-app-sg`, adding ingress rules for **22 (SSH)**, **5000 (backend)**, **5173 (frontend)** only if missing.
5. **Instance** — reuses an instance tagged `INSTANCE_NAME` (a stopped one is started, a running one is used as-is); only launches a new `t2.micro` Amazon Linux 2023 instance (latest AMI) if none exists.
6. **Elastic IP** — allocates an Elastic IP (reusing the one tagged `INSTANCE_NAME` from earlier deploys, or `EIP_ALLOCATION_ID` if set) and associates it, so the public IP never changes across stop/start.
7. **Provision** — installs Docker + the Docker Compose plugin on the instance if not already present, and enables the Docker service.
8. **Deploy** — generates `docker-compose.yml` with the Elastic IP baked into `VITE_API_URL`, validates it, copies it to the instance, then runs `docker compose pull && docker compose up -d` (MongoDB + backend + frontend).
9. **Verify** — waits until the backend API (`:5000/api/expenses`) and frontend (`:5173`) both return **HTTP 200**, then prints the public URLs.

### Usage

```bash
./deploy.sh                      # full pipeline: build, push, deploy, verify
./deploy.sh --deploy-only        # deploy only (images must already be on Docker Hub)
./deploy.sh --build-only         # build & push images only
./deploy.sh --skip-build         # skip the build; push existing local images
./deploy.sh --skip-push          # build locally but don't push
./deploy.sh --help               # full help, including all env vars
```

> The script must be run from the repo root (or set `PROJECT_ROOT`). Requires `docker login` (or `DOCKER_HUB_TOKEN`) and valid AWS credentials (`aws configure`, or the standard `AWS_*` env vars).

**Using a training lab (e.g. VOC Labs)?** The lab issues new temporary AWS credentials every time you stop and start it. After each lab start, run:

```bash
./set-aws-creds.sh    # paste the credentials block from the lab's "AWS Details" panel, then press Ctrl-D
./deploy.sh
```

`set-aws-creds.sh` backs up your previous `~/.aws/credentials`, saves the new ones, verifies them, and probes EC2 access so it fails fast (with a clear message) if the lab session is still blocked.

### Configuration (environment variables)

| Variable | Default | Description |
|----------|---------|-------------|
| `DOCKER_HUB_USER` | `yazoo555` | Docker Hub username |
| `DOCKER_HUB_TOKEN` | *(unset)* | Docker Hub access token — auto `docker login` when set |
| `DOCKER_HUB_REPO` | `yazoo555/docker-recepie` | Repository for both images |
| `PUSH_IMAGES` | `true` | Push images after building |
| `SKIP_BUILD` | `false` | Skip the build step (reuse existing local images) |
| `AWS_REGION` | `us-east-1` | AWS region |
| `KEY_NAME` | `mern-ec2-key` | EC2 key pair name |
| `KEY_PATH` | `~/.ssh/mern-ec2-key.pem` | Local path for the key PEM |
| `SG_NAME` | `mern-app-sg` | Security group name |
| `INSTANCE_NAME` | `mern-app-server` | Instance **Name tag** — reused if a running instance matches |
| `INSTANCE_TYPE` | `t2.micro` | EC2 instance type |
| `AMI_ID` | `auto` | AMI id, or `auto` for the latest Amazon Linux 2023 |
| `SSH_CIDR` | `0.0.0.0/0` | CIDR allowed to SSH in |
| `EC2_USER` | `ec2-user` | SSH user |
| `EIP_ALLOCATION_ID` | *(auto)* | Allocation ID of a specific Elastic IP to use; otherwise the EIP tagged `INSTANCE_NAME` is reused, or a new one is allocated |
| `OUTPUT_FILE` | *(unset)* | Append machine-readable results to this file (e.g. `$GITHUB_OUTPUT`) |

Example with overrides:

```bash
INSTANCE_NAME=expense-prod AWS_REGION=eu-west-1 OUTPUT_FILE=deploy.env ./deploy.sh
```

### GitHub Actions (CI/CD)

[`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) runs the full pipeline automatically on pushes to `main` (or manually via **Actions → Deploy MERN to EC2 → Run workflow**). It is idempotent, so every run safely redeploys.

**Required repository secrets** (Settings → Secrets and variables → Actions):

| Secret | Value |
|--------|-------|
| `AWS_ACCESS_KEY_ID` | AWS access key with EC2 + VPC permissions |
| `AWS_SECRET_ACCESS_KEY` | Matching AWS secret key |
| `DOCKERHUB_USERNAME` | Docker Hub username |
| `DOCKERHUB_TOKEN` | Docker Hub access token (Hub → Account Settings → Security) |

**Optional hardening:**

- Replace the AWS access keys with **OIDC** role assumption (see the comments in the workflow) for keyless, short-lived credentials.
- If you split the job into `--build-only` and `--deploy-only` jobs, persist the EC2 key PEM between jobs (artifact or secret) so the deploy job can SSH.
- `OUTPUT_FILE` is wired to GitHub Actions outputs, so the URLs from each run are printed in the workflow log.

### Teardown (cleanup)

[`destroy.sh`](destroy.sh) removes the AWS resources created by `deploy.sh` — it terminates instances tagged `INSTANCE_NAME`, releases the associated Elastic IPs (tagged `INSTANCE_NAME`, or set via `EIP_ALLOCATION_ID`) so they stop being billed, then deletes the `KEY_NAME` key pair and the `SG_NAME` security group. It accepts the same `INSTANCE_NAME` / `KEY_NAME` / `SG_NAME` / `AWS_REGION` env vars as `deploy.sh`, is idempotent, and is safety-first:

```bash
./destroy.sh                    # shows what it will delete, prompts for confirmation
./destroy.sh --yes              # skip the confirmation prompt (automatic in CI)
./destroy.sh --dry-run          # print what would be deleted — delete nothing
./destroy.sh --delete-key-file  # also remove the local PEM (~/.ssh/mern-ec2-key.pem)
./destroy.sh --help             # full help
```

> The local PEM is kept by default — pass `--delete-key-file` to remove it too (needed to re-deploy with the same key).

## Troubleshooting

### `UnauthorizedOperation` / “explicit deny” when running `deploy.sh`

If `deploy.sh` fails with an error like:

```
... is not authorized to perform: ec2:CreateKeyPair ... with an explicit deny in an identity-based policy: .../voc-cancel-cred
```

your AWS account (typically a training lab such as VOC Labs) has **revoked EC2 permissions** — this is not a bug in `deploy.sh`. The account can still authenticate (`sts` works, and Docker pushes succeed) but every EC2 API call is explicitly denied, so no EC2 deployment is possible with those credentials. This commonly appears when a lab is stopped and restarted: the lab wipes the previous resources (key pair, security group, instance) and the new session's role comes back without EC2 access.

**Fix:** restore the lab/account permissions (restart or refresh the lab, or contact the lab provider/instructor) — or run `deploy.sh` against an AWS account that has EC2 access.

`deploy.sh` (and `destroy.sh`) now detect this during preflight and stop immediately with a clear message instead of failing mid-deploy.

## API Endpoints

| Method | Endpoint            | Description                                        |
|--------|---------------------|----------------------------------------------------|
| GET    | /api/expenses       | Get all expenses (newest first)                    |
| POST   | /api/expenses       | Create a new expense                               |
| PATCH  | /api/expenses/:id   | Update description, amount, and/or category        |
| DELETE | /api/expenses/:id   | Delete an expense                                  |

## Model Fields

| Field       | Type    | Description                              |
|-------------|---------|------------------------------------------|
| description | String  | What the expense was for (required)      |
| amount      | Number  | Amount in dollars, positive (required)   |
| category    | String  | Category, e.g. "Food" (default "Other")  |
| createdAt / updatedAt | Date | Auto-managed timestamps         |
