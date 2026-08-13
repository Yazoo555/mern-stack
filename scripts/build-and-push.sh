#!/bin/bash
set -euo pipefail

# settings arrive from the environment (the workflow provides them)
FULL_NAME="$DOCKERHUB_USERNAME/$IMAGE:latest"

# log in without a prompt, using the token piped in
echo "$DOCKERHUB_TOKEN" | docker login -u "$DOCKERHUB_USERNAME" --password-stdin

echo "Building $FULL_NAME from $CONTEXT ..."
docker build -t "$FULL_NAME" "$CONTEXT"

echo "Pushing $FULL_NAME ..."
docker push "$FULL_NAME"
