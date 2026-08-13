#!/bin/bash
set -euo pipefail

FULL_NAME="$DOCKERHUB_USERNAME/$IMAGE:latest"

# Optional: when API_URL is provided (frontend deploy), pass it to the
# container as VITE_API_URL so the app can reach the backend. Leave unset
# for the backend itself.
ENV_FLAGS=""
if [[ -n "${API_URL:-}" ]]; then
  ENV_FLAGS="-e VITE_API_URL=$API_URL"
fi

# write the key from the environment to a temp file, lock it down
echo "$EC2_SSH_KEY" > key.pem
chmod 400 key.pem

# run the deploy commands on EC2 over SSH
ssh -o StrictHostKeyChecking=accept-new -i key.pem \
  "$EC2_USER@$EC2_HOST" "
    docker pull $FULL_NAME
    docker stop $CONTAINER 2>/dev/null || true
    docker rm $CONTAINER 2>/dev/null || true
    docker run -d --name $CONTAINER \
      --restart always -p $PORT:$PORT $ENV_FLAGS $FULL_NAME
  "

rm -f key.pem       # never leave the key lying around
