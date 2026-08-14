# Bootstrap de uma VPS nova

Este é o runbook operacional do VPS Deployer. Use este documento quando a VPS for nova, quando o serviço precisar ser reconstruído ou quando não houver contexto da implementação anterior.

O objetivo é sair de uma VPS acessível por SSH para um receiver de webhooks GitHub funcionando com um único processo residente.

## Premissas

- usuário com `sudo` (nos exemplos, `ubuntu`);
- IP público fixo da VPS;
- Linux com `systemd`;
- Python 3.10+;
- Git;
- para HTTPS por IP: Nginx, Certbot 5.4+ e portas 80/443 acessíveis externamente.

O repositório `marioguima/vps-deployer` é a fonte da instalação. Não clone diretamente em `/opt`; o instalador copia o runtime para os diretórios definitivos.

---

## 1. Clone no home do usuário

Entre na VPS e trabalhe a partir do home:

```bash
cd ~
```

### Caminho recomendado para bootstrap

Use HTTPS:

```bash
git clone https://github.com/marioguima/vps-deployer.git
cd vps-deployer
```

Isso evita depender de uma chave SSH do GitHub já configurada na VPS.

### Se você tentar SSH e receber `Permission denied (publickey)`

Este comando:

```bash
git clone git@github.com:marioguima/vps-deployer.git
```

pode falhar em uma VPS nova com:

```text
git@github.com: Permission denied (publickey).
fatal: Could not read from remote repository.
```

Isso significa que a conta Linux que está executando o clone ainda não possui uma chave SSH reconhecida pelo GitHub. Para o bootstrap deste deployer, não é necessário resolver SSH: volte ao clone por HTTPS.

Se aparecer primeiro:

```text
The authenticity of host 'github.com (...)' can't be established.
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

isso é apenas o primeiro contato SSH com `github.com`; aceitar o host não resolve a autenticação da chave. Se depois vier `Permission denied (publickey)`, use HTTPS.

> Se este repositório deixar de ser público no futuro, o bootstrap precisará de autenticação HTTPS ou chave SSH antes do clone. Não coloque credenciais no repositório.

---

## 2. Instale o serviço

Dentro do clone:

```bash
cd ~/vps-deployer
sudo ./scripts/install.sh
```

O instalador cria/preserva:

```text
/opt/vps-deployer/app/
/opt/vps-deployer/project-scripts/
/etc/vps-deployer/env
/etc/vps-deployer/projects.json
/var/lib/vps-deployer/
/var/log/vps-deployer/
/etc/systemd/system/vps-deployer.service
```

Em uma instalação nova, a saída deve informar que `/etc/vps-deployer/env` e `/etc/vps-deployer/projects.json` foram criados.

---

## 3. Gere e configure o segredo do webhook

Gere um segredo forte:

```bash
openssl rand -hex 32
```

Edite:

```bash
sudo nano /etc/vps-deployer/env
```

Substitua:

```env
VPS_DEPLOYER_WEBHOOK_SECRET=CHANGE_ME_WITH_A_LONG_RANDOM_SECRET
```

pelo valor gerado.

Mantenha o receiver somente no loopback quando houver Nginx na frente:

```env
VPS_DEPLOYER_BIND=127.0.0.1
VPS_DEPLOYER_PORT=9100

VPS_DEPLOYER_CONFIG=/etc/vps-deployer/projects.json
VPS_DEPLOYER_DB=/var/lib/vps-deployer/jobs.sqlite3
VPS_DEPLOYER_LOG_DIR=/var/log/vps-deployer
VPS_DEPLOYER_MAX_BODY_BYTES=1048576
VPS_DEPLOYER_LOG_LEVEL=INFO
```

O mesmo valor de `VPS_DEPLOYER_WEBHOOK_SECRET` deve ser configurado como `Secret` em todos os webhooks que apontarem para esta VPS.

Nunca cole o segredo real em issue, log público ou documentação.

---

## 4. Valide a instalação antes de iniciar

```bash
sudo vps-deployer-doctor
```

Em uma instalação ainda sem projetos, uma saída saudável é equivalente a:

```text
OK registry: /etc/vps-deployer/projects.json (0 mappings)
OK webhook secret configured
OK state directory: /var/lib/vps-deployer
OK log directory: /var/log/vps-deployer
```

---

## 5. Ative o serviço

```bash
sudo systemctl enable --now vps-deployer
sudo systemctl status vps-deployer --no-pager
```

Deve aparecer:

```text
Active: active (running)
```

Teste diretamente no processo local:

```bash
curl http://127.0.0.1:9100/health
```

Resposta esperada:

```json
{"ok":true,"service":"vps-deployer","time":"..."}
```

Neste ponto o serviço está funcionando, mas ainda não está exposto ao GitHub.

---

## 6. Prepare HTTPS no IP público

O modo recomendado não abre a porta 9100. O Nginx recebe 80/443 e encaminha `/github` e `/health` para `127.0.0.1:9100`.

Antes de executar o setup, confira:

```bash
nginx -v
certbot --version
```

Para certificados de IP via `webroot`, é obrigatório **Certbot 5.4 ou superior**.

Execute:

```bash
cd ~/vps-deployer
sudo ./scripts/setup-ip-tls.sh PUBLIC_IP SEU_EMAIL
```

Exemplo:

```bash
sudo ./scripts/setup-ip-tls.sh 203.0.113.10 email@example.com
```

### Se retornar `certbot >= 5.4 is required for webroot IP certificates`

Não altere Nginx nem abra a porta 9100 como correção. A causa é apenas um Certbot antigo.

Rode primeiro o diagnóstico:

```bash
certbot --version
command -v certbot
snap list certbot 2>/dev/null || true
dpkg -l | grep -E 'certbot|python3-certbot' || true
```

Depois siga [TROUBLESHOOTING.md](TROUBLESHOOTING.md#certbot-antigo-para-certificado-de-ip) para atualizar sem destruir configurações existentes.

Certificados de IP do Let's Encrypt usam o perfil `shortlived` e têm validade de pouco mais de seis dias; renovação automática é obrigatória.

---

## 7. Valide HTTPS externamente

Depois que `setup-ip-tls.sh` concluir:

```bash
curl https://PUBLIC_IP/health
```

Resposta esperada:

```json
{"ok":true,"service":"vps-deployer","time":"..."}
```

Não exponha `9100` à internet. Ela deve continuar ligada somente em `127.0.0.1`.

---

## 8. Só então cadastre projetos e webhooks

O receiver pode funcionar com zero projetos cadastrados. Primeiro deixe `/health` acessível por HTTPS; depois configure `/etc/vps-deployer/projects.json`, os scripts de deploy e os webhooks do GitHub.

Veja o README principal para o formato do registry e os scripts de projeto.

---

## 9. Sequência resumida para uma VPS nova

```text
SSH na VPS
  ↓
cd ~
  ↓
git clone HTTPS
  ↓
sudo ./scripts/install.sh
  ↓
openssl rand -hex 32
  ↓
configurar /etc/vps-deployer/env
  ↓
sudo vps-deployer-doctor
  ↓
sudo systemctl enable --now vps-deployer
  ↓
curl 127.0.0.1:9100/health
  ↓
garantir Certbot >= 5.4
  ↓
setup-ip-tls.sh
  ↓
curl https://PUBLIC_IP/health
  ↓
cadastrar projetos
  ↓
cadastrar webhooks GitHub
```

## Atualizando o runtime depois de mudanças neste repositório

A cópia em `~/vps-deployer` é apenas a fonte do instalador. Depois de uma atualização:

```bash
cd ~/vps-deployer
git pull
sudo ./scripts/install.sh
sudo vps-deployer-doctor
sudo systemctl restart vps-deployer
```

O instalador preserva a configuração e o estado local.