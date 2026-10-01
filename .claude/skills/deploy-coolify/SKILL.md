---
name: deploy-coolify
description: Fazer deploy deste fork do Evolution API no Coolify da VPS (serviço "evolution-api", evo.fluxosmm.com) — build da imagem própria, troca da imagem no compose do serviço, variáveis de ambiente, restart, verificação e rollback. Use quando pedirem "deploy", "subir pra produção", "atualizar a VPS" ou adicionar/alterar env vars de produção.
---

# Deploy do Evolution API no Coolify

## Como produção está montada
- Coolify v4 na VPS, API só em `http://localhost:8000/api/v1` **dentro da VPS** (acesso via SSH).
- Credenciais ficam em `~/Desktop/Projetos/Programação/ai-cloud-chat/vps.env` (`VPS_HOST`, `VPS_USER`,
  `VPS_SSH_KEY` → default `~/.ssh/looper_vps`, `COOLIFY_TOKEN`). Nunca imprimir valores.
- Evolution é um **service** (docker compose) no Coolify, não "application":
  - service uuid: `ow0ww480ssg0wwgw0ksk0gog`, app interna `api`, domínio `https://evo.fluxosmm.com`
  - containers: `api-ow0ww480ssg0wwgw0ksk0gog`, `postgres-ow0ww480ssg0wwgw0ksk0gog`, `redis-ow0ww480ssg0wwgw0ksk0gog`
- Imagem: **própria** `luizguil99/evolution-api:<versão>-<sha>` (Docker Hub). Antes de 2026-10 era a oficial
  `evoapicloud/evolution-api:v2.3.7` — ou seja, código do fork só roda se a imagem for a nossa.
- Os workflows do GitHub (`publish_docker_image*.yml`) publicam no repo do upstream; **não** servem para o deploy.
- O `.env` local NÃO é usado em produção. Env vars de prod ficam no Coolify **e** precisam estar referenciadas
  no compose (`- 'VAR=${VAR:-}'`), senão não chegam ao container.

## Helper SSH (zsh não faz word-split; use script)
```bash
cat > /tmp/vps.sh <<'EOF'
#!/bin/bash
set -a; source "$HOME/Desktop/Projetos/Programação/ai-cloud-chat/vps.env"; set +a
KEY="${VPS_SSH_KEY:-$HOME/.ssh/looper_vps}"; KEY="${KEY/#\~/$HOME}"
exec ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes "$VPS_USER@$VPS_HOST" "export COOLIFY_TOKEN='$COOLIFY_TOKEN'; $*"
EOF
chmod +x /tmp/vps.sh
# exemplo: /tmp/vps.sh 'curl -s -H "Authorization: Bearer $COOLIFY_TOKEN" http://localhost:8000/api/v1/services'
```

## Passo a passo
1. **Checar migrations novas** vs versão em prod: `git diff --name-only <tag>..HEAD -- prisma/postgresql-migrations`.
   O container roda `prisma migrate deploy` ao subir — migrations novas aplicam sozinhas (avise o usuário).
2. **Commit + push** (se o push pedir usuário: `gh auth setup-git`).
3. **Build + push da imagem** (≈3–5 min, rodar em background):
   ```bash
   SHA=$(git rev-parse --short HEAD); VER=$(node -p "require('./package.json').version")
   docker buildx build --platform linux/amd64 -f Dockerfile -t luizguil99/evolution-api:$VER-$SHA --push .
   ```
4. **Pré-pull na VPS** (reduz downtime e valida acesso): `/tmp/vps.sh "docker pull -q luizguil99/evolution-api:$VER-$SHA"`
5. **Backup do compose atual** (para rollback):
   `GET /api/v1/services/ow0ww480ssg0wwgw0ksk0gog` → salvar campo `docker_compose_raw` em arquivo (umask 077).
6. **Env var nova** (valor via stdin, nunca na linha de comando):
   ```bash
   python3 -c "import json,sys;print(json.dumps({'key':'NOME','value':sys.argv[1],'is_preview':False,'is_literal':True}))" "$VALOR" \
   | /tmp/vps.sh 'curl -s -X POST -H "Authorization: Bearer $COOLIFY_TOKEN" -H "Content-Type: application/json" --data-binary @- http://localhost:8000/api/v1/services/ow0ww480ssg0wwgw0ksk0gog/envs'
   ```
   (já existe? usar `PATCH .../envs` com o mesmo corpo.) E adicionar `- 'NOME=${NOME:-}'` no `environment` do serviço `api`.
7. **Atualizar compose** (troca só a linha `image:` do `api` + envs novas). O campo vai em **base64**:
   ```bash
   python3 -c "import json,base64;print(json.dumps({'docker_compose_raw':base64.b64encode(open('/tmp/compose.yaml').read().encode()).decode()}))" \
   | /tmp/vps.sh 'curl -s -X PATCH -H "Authorization: Bearer $COOLIFY_TOKEN" -H "Content-Type: application/json" --data-binary @- http://localhost:8000/api/v1/services/ow0ww480ssg0wwgw0ksk0gog'
   ```
8. **Restart**: `GET /api/v1/services/ow0ww480ssg0wwgw0ksk0gog/restart` → aguarde `docker ps` mostrar a imagem nova.
   Todas as instâncias WhatsApp caem ~1 min e reconectam sozinhas.

## Verificação
- `docker logs api-ow0ww480ssg0wwgw0ksk0gog` deve ter `Migration succeeded` e `HTTP - ON: 8080`.
- Endpoint de teste dentro do container (apikey global via `printenv AUTHENTICATION_API_KEY`, sem imprimir):
  `docker exec api-... sh -c "wget -qO- --header=\"apikey: $K\" http://localhost:8080/proxy/pool"`
- Status das instâncias (read-only):
  `docker exec postgres-... sh -c "psql -U \"\$POSTGRES_USER\" -d \"\${POSTGRES_DB:-postgres}\" -At -c 'select name, \"connectionStatus\" from \"Instance\"'"`
- Instância com `LOGOUT` logo após o restart = WhatsApp revogou a sessão (comum com proxy residencial que trocou
  de IP). Não é bug da imagem se instâncias sem proxy reconectaram. Precisa re-parear o QR (ver skill `whatsapp-proxy`).

## Rollback
PATCH do compose com o backup do passo 5 (ou trocar `image:` para a tag anterior) + restart.
