# TrackPixel: smoke test do fluxo de deploy via webhook

Objetivo: validar o caminho completo `GitHub push -> webhook -> allowlist -> SQLite -> worker -> script`, sem executar Docker, Nginx, migrations ou qualquer deploy real.

## Por que usar uma branch temporária

O workflow legado do TrackPixel escuta `main` e `homolog`. Para evitar que GitHub Actions tente executar em paralelo durante a validação do VPS Deployer, o smoke test usa a branch temporária:

```text
vps-deployer-smoke
```

Ela não deve ser usada para deploy real.

## 1. Instale o script de smoke na VPS

```bash
sudo tee /opt/vps-deployer/project-scripts/trackpixel-smoke.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "smoke=trackpixel-webhook"
echo "job_id=${DEPLOY_JOB_ID:-}"
echo "delivery_id=${DEPLOY_DELIVERY_ID:-}"
echo "repository=${DEPLOY_REPOSITORY:-}"
echo "branch=${DEPLOY_BRANCH:-}"
echo "sha=${DEPLOY_SHA:-}"
echo "sender=${DEPLOY_SENDER:-}"

test "${DEPLOY_REPOSITORY:-}" = "marioguima/trackpixel"
test "${DEPLOY_BRANCH:-}" = "vps-deployer-smoke"
[[ "${DEPLOY_SHA:-}" =~ ^[0-9a-f]{40}$ ]]

echo "SMOKE_TEST_OK"
EOF

sudo chmod 0755 /opt/vps-deployer/project-scripts/trackpixel-smoke.sh
```

O script não acessa o repositório privado e não precisa de `OCI_SSH_KEY` nem de credencial GitHub.

## 2. Cadastre somente a branch de smoke

Como este é o primeiro mapping da instalação, o arquivo pode ficar assim:

```bash
sudo tee /etc/vps-deployer/projects.json >/dev/null <<'EOF'
{
  "deployments": [
    {
      "repository": "marioguima/trackpixel",
      "branch": "vps-deployer-smoke",
      "command": ["/opt/vps-deployer/project-scripts/trackpixel-smoke.sh"],
      "timeout_seconds": 60,
      "enabled": true
    }
  ]
}
EOF
```

O registry é relido por webhook; não é necessário reiniciar o serviço.

Valide:

```bash
sudo vps-deployer-doctor
```

Esperado: `1 mappings` e demais verificações `OK`.

### Resultado real validado em 2026-08-14

Na primeira execução real, o `doctor` retornou:

```text
OK registry: /etc/vps-deployer/projects.json (1 mappings)
OK webhook secret configured
OK state directory: /var/lib/vps-deployer
OK log directory: /var/log/vps-deployer
```

Portanto, o script temporário e a allowlist `marioguima/trackpixel + vps-deployer-smoke` ficaram prontos para receber o primeiro `push` real.

## 3. Dispare um push real no GitHub

Crie `vps-deployer-smoke` a partir de `homolog` e faça um commit inofensivo nessa branch. O webhook já configurado no repositório deve enviar o evento `push` para:

```text
https://136.248.109.197/github
```

O workflow legado não deve ser disparado porque ele está restrito a `main` e `homolog`.

Uma forma segura no clone local do TrackPixel é:

```bash
git fetch origin
git switch homolog
git pull --ff-only origin homolog
git switch -c vps-deployer-smoke
git commit --allow-empty -m "test: validate VPS deployer webhook"
git push -u origin vps-deployer-smoke
```

Esse commit vazio existe apenas para gerar um evento `push`; não altera arquivos do TrackPixel.

## 4. Valide receiver, fila e worker

Na VPS:

```bash
sudo vps-deployer-jobs
```

O job deve terminar como `succeeded`.

Veja o log do receiver/worker:

```bash
sudo journalctl -u vps-deployer -n 100 --no-pager
```

Veja o log do job usando o ID retornado por `vps-deployer-jobs`:

```bash
sudo cat /var/log/vps-deployer/job-ID.log
```

O log deve conter:

```text
repository=marioguima/trackpixel
branch=vps-deployer-smoke
SMOKE_TEST_OK
```

## 5. Critério de sucesso

O smoke test está concluído somente quando:

1. GitHub mostra a entrega `push` com resposta 202;
2. `vps-deployer-jobs` mostra o job como `succeeded`;
3. o log do job contém `SMOKE_TEST_OK`;
4. nenhum deploy real foi executado;
5. o workflow legado de `main/homolog` não participou do teste.

Depois disso, substituir o mapping temporário pelo deploy real de `homolog`.

## OCI_SSH_KEY

Não remover `OCI_SSH_KEY` antes de validar o deploy real de `homolog`. O workflow legado ainda depende dessa secret para SSH/SCP. No modelo novo o deployer roda dentro da VPS, portanto a secret de acesso SSH à própria VPS deixa de ser necessária quando o workflow antigo for aposentado.

A autenticação futura para ler o repositório privado é uma credencial separada e deve ser configurada para o usuário `vps-deployer` com o menor privilégio possível.

## Webhook de organização

Quando o TrackPixel for movido para uma organização, pode-se usar um único webhook de organização para `push` apontando para o mesmo endpoint. O `projects.json` continua sendo a allowlist local de `repository + branch`, então pushes de repositórios não cadastrados são ignorados.