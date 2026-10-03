#!/usr/bin/env bash
# Brings up the full IntBuddy stack on the EC2 host, in dependency order:
#   mysql -> redis -> backend -> frontend -> nginx
#
# Expected layout on the host:
#   /opt/intbuddy/deployment          (this repo)
#   /opt/intbuddy/deployment/env/mysql.env
#   /opt/intbuddy/env/backend.env     (written by the backend CI workflow)
#   /opt/intbuddy/IntBuddyBackend     (cloned automatically)
#   /opt/intbuddy/IntBuddy_Frontend   (cloned automatically)
set -euo pipefail

BASE=/opt/intbuddy
DEPLOY_DIR="$BASE/deployment"

echo "== Disk usage before cleanup"
df -h /

echo "== Removing unused Docker images and build cache"
docker image prune -af
docker builder prune -af

for f in "$DEPLOY_DIR/env/mysql.env" "$BASE/env/backend.env"; do
  if [ ! -f "$f" ]; then
    echo "Missing $f - create it before running this script" >&2
    exit 1
  fi
done

docker network create intbuddy-network 2>/dev/null || true

clone_or_update() {
  local repo=$1 dir=$2
  if [ ! -d "$dir/.git" ]; then
    git clone "https://github.com/AmarBhise97/$repo.git" "$dir"
  else
    git -C "$dir" fetch origin main
    git -C "$dir" reset --hard origin/main
  fi
}

clone_or_update IntBuddyDeployment "$DEPLOY_DIR"
clone_or_update IntBuddyBackend    "$BASE/IntBuddyBackend"
clone_or_update IntBuddy_Frontend  "$BASE/IntBuddy_Frontend"

is_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]
}

# Never recreate the stateful services if they are already up
echo "== MySQL"
is_running intbuddy-mysql && echo "already running" || docker compose -f "$DEPLOY_DIR/mysql/docker-compose.mysql.yml" up -d

echo "== Redis"
is_running intbuddy-redis && echo "already running" || docker compose -f "$DEPLOY_DIR/redis/docker-compose.redis.yml" up -d

echo "== Backend"
docker compose -f "$BASE/IntBuddyBackend/docker-compose.yml" pull
docker compose -f "$BASE/IntBuddyBackend/docker-compose.yml" up -d

echo "== Frontend"
docker compose -f "$BASE/IntBuddy_Frontend/docker-compose.yml" pull
docker compose -f "$BASE/IntBuddy_Frontend/docker-compose.yml" up -d

echo "== Nginx"
docker compose -f "$DEPLOY_DIR/nginx/docker-compose.yml" up -d --force-recreate

docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
df -h /
