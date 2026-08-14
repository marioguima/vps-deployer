# TrackPixel — debug do primeiro deploy real em homolog (2026-08-14)

Registro dos problemas encontrados durante o primeiro deploy real do TrackPixel via VPS Deployer. O objetivo é evitar repetir diagnóstico manual ao reconstruir outra VPS.

## Fluxo validado antes dos erros de build

O push em `marioguima/trackpixel@homolog` chegou corretamente por:

```text
GitHub push
→ webhook assinado
→ allowlist repo+branch
→ fila SQLite
→ worker serializado
→ GitHub App
→ checkout do SHA exato
→ adapter TrackPixel
```

O `project_id` real criado no primeiro onboarding foi `trackpixel--cb886e1a6384`.

## 1. `docker is required`

Causa real: Docker ainda não estava instalado na VPS.

Correção estrutural:

- `scripts/bootstrap-host.sh` passou a verificar Docker uma vez durante o bootstrap;
- se Docker/Compose já estiverem saudáveis, não reinstala;
- se estiverem ausentes, instala Docker Engine, CLI, containerd, Buildx e Compose plugin pelo repositório oficial;
- onboarding do TrackPixel deve acontecer somente depois do bootstrap da infraestrutura.

## 2. `mkdir /root/.docker: read-only file system`

Causa: o adapter é chamado via `sudo`, mas o serviço `vps-deployer` mantém `ProtectHome=true`. Docker tentou usar `/root/.docker`, que fica corretamente inacessível nesse contexto.

Correção: o adapter define `DOCKER_CONFIG` dentro do workspace estável do projeto/ambiente, em vez de liberar acesso a `/root` ou enfraquecer o sandbox do systemd.

## 3. Prisma generate falha com `Cannot resolve environment variable: DATABASE_URL`

Sintoma durante `docker compose build`:

```text
PrismaConfigEnvError: Cannot resolve environment variable: DATABASE_URL
RUN npx prisma generate
```

Causa: `prisma.config.ts` usa `env('DATABASE_URL')`. Prisma carrega esse arquivo também durante `prisma generate`, apesar de a geração do client não precisar conectar ao banco. Os Dockerfiles de API e Worker executavam `npx prisma generate` sem uma `DATABASE_URL` disponível no estágio de build.

Correção escolhida no próprio TrackPixel, sem alterar integridade do checkout e sem colocar segredo de produção no build:

```dockerfile
RUN DATABASE_URL=postgresql://trackpixel:build-only@localhost:5432/trackpixel npx prisma generate
```

Esse valor é deliberadamente fictício e existe somente no comando de geração. Runtime e migrations continuam recebendo a `DATABASE_URL` real via Docker Compose.

Arquivos corrigidos em `homolog`:

- `apps/api/Dockerfile`
- `apps/worker/Dockerfile`

## Regra operacional

Não corrigir falhas do código do projeto modificando arquivos do checkout na VPS. O checkout precisa continuar correspondendo exatamente ao SHA recebido pelo webhook. Correções de aplicação devem entrar no repositório e produzir um novo push/SHA; o deployer então implanta esse novo SHA automaticamente.
