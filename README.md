# VPS Deployer

Um deployer global, pequeno e independente de GitHub Actions para uma VPS.

Ele recebe eventos `push` do GitHub, valida a assinatura do webhook, identifica `owner/repo + branch`, coloca o deploy em uma fila persistente e executa **um deploy por vez** usando scripts previamente cadastrados na VPS.

Foi desenhado para atender repositórios pessoais e de múltiplas organizações com **um único serviço**.

```text
GitHub repo/org webhooks
          │
          │ push
          ▼
https://PUBLIC_IP/github
          │
          ▼
    vps-deployer
     1 processo
          │
          ▼
      SQLite queue
          │
          ▼
  1 deploy por vez
          │
    ┌─────┼─────┐
    ▼     ▼     ▼
 repo A  repo B repo C
```

## Se você voltou aqui meses depois

Não tente reconstruir a instalação de memória.

Comece por **[docs/BOOTSTRAP.md](docs/BOOTSTRAP.md)**. Esse runbook registra o procedimento real desde uma VPS nova, incluindo os problemas já encontrados durante a primeira instalação.

Se alguma etapa falhar, consulte **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**.

Problemas já documentados:

- clone SSH em VPS nova falhando com `Permission denied (publickey)` e fallback por HTTPS;
- confirmação inicial da fingerprint de `github.com`;
- Certbot anterior a 5.4 impedindo certificado TLS para IP;
- `/health` local funcionando mas acesso externo falhando;
- comandos para diagnosticar serviço, Nginx e portas.

## Por que existe

GitHub-hosted Actions consomem a franquia de minutos. Self-hosted runners resolvem o custo, mas runners sem GitHub Enterprise ficam limitados ao escopo de um repositório ou de uma organização. Quando a mesma VPS recebe projetos de uma conta pessoal e de várias organizações, isso força múltiplos runners.

O VPS Deployer evita esse acoplamento:

- não usa GitHub Actions;
- não usa polling;
- não exige GitHub Enterprise;
- não exige um domínio;
- não exige Redis, banco externo ou container;
- aceita webhooks de qualquer repositório/organização configurado;
- mantém apenas um processo residente;
- serializa os builds para não sobrecarregar a VPS.

## Requisitos

Base:

- Linux com `systemd`;
- Python 3.10+;
- Git.

Para HTTPS por IP:

- IP público fixo;
- Nginx;
- Certbot **5.4+**;
- portas TCP 80 e 443 liberadas na VPS e no firewall/security-list do provedor.

O próprio deployer não depende de Docker. Docker é necessário somente para projetos cujos scripts de deploy o utilizem.

---

# Instalação rápida

O procedimento detalhado e canônico está em [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md). O resumo é:

```bash
cd ~
git clone https://github.com/marioguima/vps-deployer.git
cd vps-deployer
sudo ./scripts/install.sh
```

> Em uma VPS nova prefira o clone HTTPS. `git@github.com:...` depende de uma chave SSH previamente autorizada e pode falhar com `Permission denied (publickey)`. Esse caso está documentado no runbook.

Gere o segredo:

```bash
openssl rand -hex 32
sudo nano /etc/vps-deployer/env
```

Mantenha:

```env
VPS_DEPLOYER_BIND=127.0.0.1
VPS_DEPLOYER_PORT=9100
```

Valide e inicie:

```bash
sudo vps-deployer-doctor
sudo systemctl enable --now vps-deployer
sudo systemctl status vps-deployer --no-pager
curl http://127.0.0.1:9100/health
```

Resposta esperada:

```json
{"ok":true,"service":"vps-deployer","time":"..."}
```

## Diretórios criados

```text
/opt/vps-deployer/app/                 código em execução
/opt/vps-deployer/project-scripts/     scripts de cada projeto
/etc/vps-deployer/env                  segredo/configuração do receiver
/etc/vps-deployer/projects.json        registry repo + branch -> script
/var/lib/vps-deployer/jobs.sqlite3     fila e histórico
/var/log/vps-deployer/                 logs dos deploys
/etc/systemd/system/vps-deployer.service
```

O instalador cria o usuário de sistema `vps-deployer`. Se o grupo `docker` já existir, ele é adicionado ao grupo para permitir que scripts de projeto chamem Docker.

> Acesso ao grupo `docker` é efetivamente privilegiado. Leia [docs/SECURITY.md](docs/SECURITY.md).

---

# HTTPS usando somente o IP público

Um domínio não é necessário.

Let's Encrypt emite certificados para endereços IP usando o perfil `shortlived`. Para `webroot`, este projeto exige Certbot 5.4+.

Antes:

```bash
certbot --version
```

Depois execute:

```bash
sudo ./scripts/setup-ip-tls.sh PUBLIC_IP SEU_EMAIL
```

O script:

1. valida Nginx e a versão do Certbot;
2. publica o challenge HTTP em `:80`;
3. solicita certificado para o IP;
4. configura Nginx em `:443`;
5. mantém o Python somente em `127.0.0.1:9100`;
6. instala hook de reload do Nginx após renovações.

Se retornar:

```text
certbot >= 5.4 is required for webroot IP certificates
```

não abra a porta 9100 e não altere Nginx manualmente. Siga a seção **Certbot antigo para certificado de IP** em [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md#certbot-antigo-para-certificado-de-ip).

Depois do setup:

```bash
curl https://PUBLIC_IP/health
```

Endpoints:

```text
Webhook: https://PUBLIC_IP/github
Health:  https://PUBLIC_IP/health
```

A porta `9100` deve continuar privada em `127.0.0.1`.

---

# Cadastre os projetos

Edite:

```bash
sudo nano /etc/vps-deployer/projects.json
```

Exemplo:

```json
{
  "deployments": [
    {
      "repository": "marioguima/projeto-a",
      "branch": "homolog",
      "command": ["/opt/vps-deployer/project-scripts/projeto-a.sh", "homolog"],
      "timeout_seconds": 1800,
      "enabled": true
    },
    {
      "repository": "Organizacao/projeto-b",
      "branch": "main",
      "command": ["/opt/vps-deployer/project-scripts/projeto-b.sh", "production"],
      "timeout_seconds": 1800,
      "enabled": true
    }
  ]
}
```

O arquivo é relido quando cada webhook chega. Adicionar projeto não exige restart.

O payload recebido nunca vira comando shell. O webhook apenas seleciona uma correspondência exata de `repository + branch`; o comando vem deste arquivo local.

## Script de deploy de cada projeto

O deployer fornece:

```text
DEPLOY_JOB_ID
DEPLOY_DELIVERY_ID
DEPLOY_REPOSITORY
DEPLOY_REF
DEPLOY_BRANCH
DEPLOY_SHA
DEPLOY_SENDER
```

Há um exemplo em:

```text
examples/deploy-git-docker-compose.sh
```

Os scripts devem implantar **`DEPLOY_SHA`**, não simplesmente a ponta atual da branch.

Para repositórios privados, configure autenticação Git para o usuário `vps-deployer` com a menor permissão necessária. Não coloque chaves privadas neste repositório.

---

# Configurando o GitHub

## Repositório individual

```text
Settings
→ Webhooks
→ Add webhook
```

Configure:

```text
Payload URL:  https://PUBLIC_IP/github
Content type: application/json
Secret:       mesmo VPS_DEPLOYER_WEBHOOK_SECRET
Events:       Just the push event
Active:       marcado
```

O GitHub envia um `ping` ao criar o webhook; o receiver responde `200`.

## Organização

Quando você administra webhooks da organização, configure um único webhook de organização para `push` apontando para o mesmo endpoint. Repositórios/branches não cadastrados em `projects.json` são ignorados.

Para repositórios pessoais, cadastre o webhook apenas nos repositórios que devem fazer deploy nessa VPS.

---

# Funcionamento

Para cada request:

1. aceita somente `POST /github`;
2. limita o payload;
3. valida `X-Hub-Signature-256` sobre o body original usando HMAC-SHA256;
4. usa `X-GitHub-Delivery` para idempotência;
5. aceita `ping` e `push`;
6. lê `repository.full_name`, `ref` e `after`;
7. procura correspondência exata em `projects.json`;
8. persiste o job no SQLite;
9. responde `202` sem esperar o deploy;
10. um único worker executa os jobs em ordem.

Se o serviço reiniciar durante um deploy, jobs `running` voltam para `queued`.

---

# Operação diária

Status:

```bash
sudo systemctl status vps-deployer
```

Receiver/worker:

```bash
sudo journalctl -u vps-deployer -f
```

Deploys:

```bash
sudo vps-deployer-jobs
```

Log:

```bash
sudo less /var/log/vps-deployer/job-ID.log
```

Retry:

```bash
sudo vps-deployer-retry ID
```

---

# Atualizando o VPS Deployer

Na cópia clonada:

```bash
cd ~/vps-deployer
git pull
sudo ./scripts/install.sh
sudo vps-deployer-doctor
sudo systemctl restart vps-deployer
```

O instalador preserva:

- `/etc/vps-deployer/env`;
- `/etc/vps-deployer/projects.json`;
- SQLite;
- logs;
- scripts específicos dos projetos.

---

# Backup e migração

Código: clone novamente este repositório.

Backup obrigatório do estado/configuração:

```text
/etc/vps-deployer/
/opt/vps-deployer/project-scripts/
```

Opcional para histórico:

```text
/var/lib/vps-deployer/jobs.sqlite3
/var/log/vps-deployer/
```

Na VPS nova, siga [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md), restaure a configuração/scripts, configure HTTPS para o novo IP e altere os Payload URLs dos webhooks.

---

# Modo HTTP direto — apenas emergência

É possível usar temporariamente:

```env
VPS_DEPLOYER_BIND=0.0.0.0
VPS_DEPLOYER_PORT=9100
```

mas isso não fornece confidencialidade de transporte. O desenho normal é HTTPS por Nginx e `127.0.0.1:9100`.

---

# Testes

```bash
python3 -m unittest discover -s tests -v
bash -n scripts/*.sh examples/*.sh
```

## Princípios

- global, não ligado a produto/empresa;
- um processo por VPS;
- evento, não polling;
- fila persistente;
- deploy serial por padrão;
- configuração explícita por repositório e branch;
- payload nunca controla comando arbitrário;
- sem GitHub Actions e sem minutos de runner hospedado;
- instalação reproduzível e documentação suficiente para reconstrução meses depois.

## Documentação

- [Bootstrap/reconstrução](docs/BOOTSTRAP.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Segurança](docs/SECURITY.md)
