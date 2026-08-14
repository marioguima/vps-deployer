# Bootstrap de uma VPS nova

Este é o runbook operacional do VPS Deployer. Use este documento quando a VPS for nova, quando o serviço precisar ser reconstruído ou quando não houver contexto da implementação anterior.

O objetivo é sair de uma VPS acessível por SSH para um receiver de webhooks GitHub funcionando com um único processo residente e com as dependências de host necessárias aos adapters habilitados.

## Premissas

- usuário com `sudo` (nos exemplos, `ubuntu`);
- IP público fixo da VPS;
- Ubuntu com `systemd`;
- Python 3.10+;
- Git;
- para HTTPS por IP: Nginx, Certbot 5.4+ e portas 80/443 acessíveis externamente.

O repositório `marioguima/vps-deployer` é a fonte da instalação. Não clone diretamente em `/opt`; o instalador copia o runtime para os diretórios definitivos.

---

## 1. Clone no home do usuário

Entre na VPS e trabalhe a partir do home:

```bash
cd ~
git clone https://github.com/marioguima/vps-deployer.git
cd vps-deployer
```

Use HTTPS no bootstrap para não depender de uma chave SSH do GitHub já configurada na VPS.

Se o clone por SSH falhar com `Permission denied (publickey)`, não é necessário corrigir SSH para instalar o deployer; use HTTPS.

---

## 2. Prepare as dependências do host uma única vez

Antes de cadastrar projetos, execute:

```bash
cd ~/vps-deployer
sudo ./scripts/bootstrap-host.sh
```

Esse bootstrap é idempotente:

```text
Docker + Compose já disponíveis
  -> valida
  -> não reinstala

Docker + Compose ausentes
  -> configura o repositório APT oficial da Docker
  -> instala Docker Engine + Buildx + Compose plugin
  -> habilita/inicia docker.service
  -> valida a instalação
```

O script não é executado durante cada deploy. Ele pertence somente à preparação/reconstrução da VPS.

Não usamos um arquivo-marcador do tipo `docker-installed`: se o bootstrap for executado novamente, ele verifica o estado real. Isso evita considerar o host saudável caso o Docker tenha sido removido ou quebrado depois.

Por segurança, se forem detectados pacotes de runtime potencialmente conflitantes (`docker.io`, `containerd`, `runc`, etc.), o bootstrap para em vez de removê-los silenciosamente de uma VPS que possa ter outras cargas.

Depois que o VPS Deployer estiver instalado, o mesmo bootstrap também fica disponível como:

```bash
sudo vps-deployer-bootstrap-host
```

### Regra para adapters que dependem de Docker

O onboarding do TrackPixel valida Docker Engine, Docker Compose e `docker.service` **antes de alterar a allowlist ou criar o projeto**.

Se o host ainda não estiver preparado, o onboarding falha imediatamente orientando executar:

```bash
sudo vps-deployer-bootstrap-host
```

Assim a falta de Docker é detectada no onboarding, e não somente depois de um push real.

---

## 3. Instale o VPS Deployer

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

Também instala os helpers operacionais em `/usr/local/bin`, incluindo:

```text
vps-deployer-bootstrap-host
vps-deployer-git
vps-deployer-checkout
vps-deployer-onboard-trackpixel
vps-deployer-doctor
vps-deployer-jobs
vps-deployer-retry
```

O usuário `vps-deployer` não é colocado no grupo `docker`. Adapters privilegiados usam regras `sudo` restritas.

---

## 4. Gere e configure o segredo do webhook

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

O mesmo `VPS_DEPLOYER_WEBHOOK_SECRET` deve ser configurado nos webhooks que apontarem para esta VPS. Nunca registre o segredo real em documentação ou logs públicos.

---

## 5. Valide a instalação antes de iniciar

```bash
sudo vps-deployer-doctor
```

Em uma instalação sem projetos, uma saída saudável é equivalente a:

```text
OK registry: /etc/vps-deployer/projects.json (0 mappings)
OK webhook secret configured
OK state directory: /var/lib/vps-deployer
OK log directory: /var/log/vps-deployer
```

---

## 6. Ative o serviço

```bash
sudo systemctl enable --now vps-deployer
sudo systemctl status vps-deployer --no-pager
```

Deve aparecer `Active: active (running)`.

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

## 7. Prepare HTTPS no IP público

O modo recomendado não abre a porta 9100. O Nginx recebe 80/443 e encaminha `/github` e `/health` para `127.0.0.1:9100`.

Antes do setup, confira:

```bash
nginx -v
certbot --version
```

Para certificados de IP via `webroot`, é obrigatório Certbot 5.4 ou superior.

Execute:

```bash
cd ~/vps-deployer
sudo ./scripts/setup-ip-tls.sh PUBLIC_IP SEU_EMAIL
```

Se houver Certbot antigo, consulte `TROUBLESHOOTING.md` antes de alterar Nginx ou expor a porta 9100.

---

## 8. Valide HTTPS externamente

```bash
curl https://PUBLIC_IP/health
```

Resposta esperada:

```json
{"ok":true,"service":"vps-deployer","time":"..."}
```

A porta 9100 deve continuar ligada somente em `127.0.0.1`.

---

## 9. Só então cadastre projetos e webhooks

Primeiro deixe a infraestrutura saudável; depois execute o onboarding do adapter necessário.

Para TrackPixel:

```bash
sudo vps-deployer-onboard-trackpixel --repository owner/trackpixel
```

Esse comando recusa o onboarding caso Docker/Compose ainda não estejam saudáveis.

Depois configure os webhooks do GitHub.

---

## 10. Sequência resumida para uma VPS nova

```text
SSH na VPS
  ↓
clone HTTPS do vps-deployer
  ↓
bootstrap-host.sh
  ├─ Docker já existe -> valida apenas
  └─ Docker ausente   -> instala uma vez
  ↓
install.sh
  ↓
configurar webhook secret
  ↓
vps-deployer-doctor
  ↓
ativar serviço
  ↓
configurar HTTPS
  ↓
validar /health
  ↓
onboarding dos projetos
  ↓
webhooks GitHub
  ↓
push passa a ser a operação normal
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

Não execute `bootstrap-host` a cada atualização normal. Ele só é necessário no bootstrap/reconstrução do host ou para reparar uma dependência de host ausente.

O instalador preserva a configuração e o estado local.
