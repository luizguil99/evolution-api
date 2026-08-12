#!/usr/bin/env bash
# Start local Evolution API stack (Postgres + Redis deps + API).
#
# Usage:
#   ./scripts/start-local.sh           # deps + npm run dev:server
#   ./scripts/start-local.sh --deps    # only Postgres/Redis
#   ./scripts/start-local.sh --stop    # stop deps

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MODE="all"
case "${1:-}" in
  --deps) MODE="deps" ;;
  --stop) MODE="stop" ;;
  -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
esac

start_deps() {
  echo "==> Starting local Postgres + Redis"
  if [[ -f Docker/postgres/docker-compose.yaml ]]; then
    docker compose -f Docker/postgres/docker-compose.yaml up -d
  elif [[ -f Docker/postgres/docker-compose.yml ]]; then
    docker compose -f Docker/postgres/docker-compose.yml up -d
  fi
  if [[ -f Docker/redis/docker-compose.yaml ]]; then
    docker compose -f Docker/redis/docker-compose.yaml up -d
  elif [[ -f Docker/redis/docker-compose.yml ]]; then
    docker compose -f Docker/redis/docker-compose.yml up -d
  fi
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | head -20
}

stop_deps() {
  echo "==> Stopping local Postgres + Redis"
  docker compose -f Docker/postgres/docker-compose.yaml down 2>/dev/null || true
  docker compose -f Docker/postgres/docker-compose.yml down 2>/dev/null || true
  docker compose -f Docker/redis/docker-compose.yaml down 2>/dev/null || true
  docker compose -f Docker/redis/docker-compose.yml down 2>/dev/null || true
}

if [[ "$MODE" == "stop" ]]; then
  stop_deps
  exit 0
fi

start_deps

if [[ "$MODE" == "deps" ]]; then
  exit 0
fi

if [[ ! -f .env ]]; then
  echo "Missing .env — copy from .env.example first" >&2
  exit 1
fi

export DATABASE_PROVIDER="${DATABASE_PROVIDER:-postgresql}"
echo "==> Generating Prisma client / ensuring migrations"
npm run db:generate
npm run db:deploy || true

echo "==> Starting API on :8080 (dev)"
exec npm run dev:server
