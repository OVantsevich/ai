#!/bin/sh
# Imports the Postgres credential and the workflows into n8n, publishes them and restarts n8n.
set -eu

cd "$(dirname "$0")/../.."
env_file=platform/deploy/.env
val() { grep "^$1=" "$env_file" | cut -d= -f2-; }

printf '[{"id":"aiPostgres000001","name":"AI Postgres","type":"postgres","data":{"host":"postgres","port":5432,"database":"%s","user":"%s","password":"%s","ssl":"disable"}}]' \
  "$(val POSTGRES_DB)" "$(val POSTGRES_USER)" "$(val POSTGRES_PASSWORD)" |
  docker exec -i n8n sh -c 'umask 077; cat > /tmp/ai-credentials.json; n8n import:credentials --input=/tmp/ai-credentials.json; rm -f /tmp/ai-credentials.json'

docker exec n8n sh -c 'rm -rf /tmp/ai-workflows && mkdir -p /tmp/ai-workflows'
docker cp platform/orchestrator/workflows/. n8n:/tmp/ai-workflows/
docker exec n8n n8n import:workflow --separate --input=/tmp/ai-workflows

for id in aiEngine00000001 aiRoleResult0001 aiTaskForm000001 aiTelegram000001; do
  docker exec n8n n8n publish:workflow --id="$id"
done

docker restart n8n >/dev/null
echo "n8n restarted with published AI workflows"
