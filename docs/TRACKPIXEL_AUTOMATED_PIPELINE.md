# TrackPixel — esteira automática na VPS

Objetivo: depois do onboarding, nenhum deploy exige SSH/SCP/comando manual. Push em `homolog` publica homologação; push em `main` publica produção.

## Identidade estável do projeto

No primeiro onboarding o VPS Deployer gera uma identidade local no formato:

```text
<repo-name>--<12 hex>
```

Exemplo:

```text
trackpixel--a1b2c3d4e5f6
```

Ela fica em `/etc/vps-deployer/projects.json` e define o workspace:

```text
/var/lib/vps-deployer/workspaces/<project_id>/homolog
/var/lib/vps-deployer/workspaces/<project_id>/production
```

`project_id` não vem do webhook nem do manifesto versionado. Ele permanece igual quando o repositório muda de owner.

## Primeiro onboarding

Na VPS, no checkout do `vps-deployer`:

```bash
cd ~/vps-deployer
git fetch origin
git switch docs/bootstrap-tls-sni-2026-08-14
git pull --ff-only

python3 -m unittest discover -s tests -v
python3 -m py_compile scripts/github_app_git.py scripts/onboard_trackpixel.py src/vps_deployer.py
bash -n scripts/*.sh adapters/*.sh examples/*.sh

sudo ./scripts/install.sh
sudo vps-deployer-onboard-trackpixel --repository marioguima/trackpixel
sudo vps-deployer-doctor
sudo systemctl restart vps-deployer
sudo systemctl is-active vps-deployer
sudo nginx -t
```

O comando de onboarding imprime o `project_id` gerado e cria as duas mappings:

```text
marioguima/trackpixel + homolog -> TrackPixel homolog
marioguima/trackpixel + main    -> TrackPixel production
```

## Primeiro teste real

Depois do onboarding, criar um novo commit em `homolog` e fazer push. A partir desse momento não executar o adapter manualmente.

Fluxo esperado:

```text
push homolog
-> webhook HTTPS
-> assinatura HMAC
-> allowlist repository+branch
-> fila SQLite
-> worker
-> sudo adapter TrackPixel previamente autorizado
-> GitHub App
-> installation token temporário
-> checkout do SHA completo
-> preserva/cria .env do ambiente
-> docker compose build
-> postgres + redis
-> prisma migrate deploy
-> api + worker + pixel
-> Nginx + Certbot quando necessário
-> health checks
-> job succeeded
```

Acompanhar sem interferir:

```bash
sudo vps-deployer-jobs
sudo journalctl -u vps-deployer -f
```

Para um job específico:

```bash
sudo cat /var/log/vps-deployer/job-ID.log
```

## Transferência para organização

Depois que homolog funcionar no owner atual:

1. transferir o repositório no GitHub;
2. instalar a mesma GitHub App na organização;
3. criar/configurar o webhook da organização;
4. atualizar a allowlist preservando o `project_id`:

```bash
sudo vps-deployer-onboard-trackpixel \
  --from-repository marioguima/trackpixel \
  --repository NOVA_ORG/trackpixel
```

O comando encontra o `project_id` antigo, remove as mappings do owner anterior e cria as mappings para o owner novo sem mover o workspace.

No primeiro deploy depois da transferência, `vps-deployer-checkout` atualiza automaticamente o Git remote `origin` de um URL GitHub HTTPS autorizado para o novo `owner/repo`.

O que deve permanecer igual:

```text
project_id
workspace
.env homolog
.env production
Docker Compose project names
volumes persistentes
```

O que muda:

```text
repository: marioguima/trackpixel -> NOVA_ORG/trackpixel
GitHub App installation/organization webhook
```

## Manifesto TrackPixel

O repositório contém `.vps-deployer.json` com configuração não secreta.

Homolog atual:

```text
track-homolog.intellifyads.com:3100
pixel-homolog.intellifyads.com:3101
compose project: trackpixel-homolog
```

Production atual:

```text
track.intellifyads.com:3000
pixel.intellifyads.com:3001
compose project: trackpixel-production
```

Segredos são gerados/preservados na VPS e nunca entram no manifesto ou logs.

## Aposentar GitHub Actions

Somente depois de:

1. homolog funcionar automaticamente no owner atual;
2. transferência para organização funcionar preservando workspace;
3. production ser validado;

então desativar `.github/workflows/deploy.yml` e remover `OCI_SSH_KEY`.
