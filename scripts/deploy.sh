#!/usr/bin/env bash
# Redeploy Evolution API image to Docker Hub and optionally restart remote/local stack.
#
# Usage:
#   ./scripts/deploy.sh                  # build+push latest + VERSION tag
#   ./scripts/deploy.sh --remote         # build+push and restart VPS stack via SSH
#   ./scripts/deploy.sh --local          # restart local docker compose (no push)
#   ./scripts/deploy.sh --tag 2.3.7-local
#
# Env (optional, defaults below):
#   DOCKER_IMAGE, DOCKER_TAG, PLATFORM, REMOTE_HOST, REMOTE_DIR, REMOTE_USER
#   LOCAL_COMPOSE_FILE

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DOCKER_IMAGE="${DOCKER_IMAGE:-luizguil99/evolution-api}"
DOCKER_TAG="${DOCKER_TAG:-latest}"
PLATFORM="${PLATFORM:-linux/amd64}"
REMOTE_USER="${REMOTE_USER:-root}"
REMOTE_HOST="${REMOTE_HOST:-109.123.249.187}"
REMOTE_DIR="${REMOTE_DIR:-/opt/evoapi-fluxosmm}"
LOCAL_COMPOSE_FILE="${LOCAL_COMPOSE_FILE:-docker-compose.yaml}"

DO_REMOTE=false
DO_LOCAL=false
SKIP_BUILD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote) DO_REMOTE=true; shift ;;
    --local) DO_LOCAL=true; shift ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --tag) DOCKER_TAG="$2"; shift 2 ;;
    --image) DOCKER_IMAGE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

VERSION_TAG="$(node -p "require('./package.json').version" 2>/dev/null || echo "dev")"
EXTRA_TAG="${VERSION_TAG}-local"

echo "==> Image: ${DOCKER_IMAGE}"
echo "==> Tags:  ${DOCKER_TAG}, ${EXTRA_TAG}"
echo "==> Platform: ${PLATFORM}"

if [[ "$DO_LOCAL" == "true" && "$DO_REMOTE" != "true" ]]; then
  SKIP_BUILD=true
fi

if [[ "$SKIP_BUILD" != "true" ]]; then
  echo "==> Building and pushing..."
  docker buildx build \
    --platform "$PLATFORM" \
    -t "${DOCKER_IMAGE}:${DOCKER_TAG}" \
    -t "${DOCKER_IMAGE}:${EXTRA_TAG}" \
    --push \
    .
  echo "==> Push OK"
else
  echo "==> Skipping build/push"
fi

restart_compose() {
  local dir="$1"
  local compose_file="${2:-docker-compose.yml}"
  echo "==> Restarting stack in ${dir} (${compose_file})"
  (
    cd "$dir"
    if [[ -f "$compose_file" ]]; then
      docker compose -f "$compose_file" pull
      docker compose -f "$compose_file" up -d --remove-orphans
    else
      docker compose pull
      docker compose up -d --remove-orphans
    fi
    docker compose ps
  )
}

if [[ "$DO_LOCAL" == "true" ]]; then
  if [[ ! -f "$ROOT_DIR/$LOCAL_COMPOSE_FILE" ]]; then
    echo "Local compose not found: $LOCAL_COMPOSE_FILE" >&2
    echo "Tip: use Docker/postgres + Docker/redis for deps and npm run dev:server for API." >&2
    exit 1
  fi
  restart_compose "$ROOT_DIR" "$LOCAL_COMPOSE_FILE"
fi

if [[ "$DO_REMOTE" == "true" ]]; then
  echo "==> Redeploying on ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}"
  ssh -o StrictHostKeyChecking=accept-new "${REMOTE_USER}@${REMOTE_HOST}" bash -s <<EOF
set -euo pipefail
cd "${REMOTE_DIR}"
docker compose pull
docker compose up -d --remove-orphans
docker compose ps
curl -sk -o /dev/null -w "HTTP %{http_code}\\n" "\${SERVER_URL:-https://evoapi.fluxosmm.com}" || true
EOF
  echo "==> Remote redeploy OK"
fi

if [[ "$DO_LOCAL" != "true" && "$DO_REMOTE" != "true" ]]; then
  echo
  echo "Build/push finished. To restart stacks:"
  echo "  ./scripts/deploy.sh --remote          # VPS"
  echo "  ./scripts/deploy.sh --local           # local compose"
  echo "  ./scripts/deploy.sh --skip-build --remote"
fi
