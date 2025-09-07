#!/usr/bin/env bash
set -e

ENV="$1"
if [ -z "$ENV" ]; then
  echo "Usage: $0 <environment>  (e.g. ./rebuild_docker.sh hmg)"
  exit 1
fi

COMPOSE_FILE="docker-compose.${ENV}.yaml"
echo "Using compose file: ${COMPOSE_FILE}"
echo "Stopping containers..."
docker compose -f "${COMPOSE_FILE}" down

echo "Starting containers with ${COMPOSE_FILE}..."
COMPOSE_BAKE=true docker compose -f "${COMPOSE_FILE}" up -d --build

echo "Done."