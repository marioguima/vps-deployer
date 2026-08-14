# Nginx: HTTPS por IP literal em VPS com vários sites

Este runbook cobre o caso em que o certificado do IP público foi emitido corretamente, mas `curl https://PUBLIC_IP/health` falha durante o handshake TLS com erro semelhante a `tlsv1 unrecognized name`.

## Causa

HTTPS por IP literal não pode depender de SNI para selecionar o virtual host. Em uma VPS que já possui um `listen 443 ssl default_server` com `ssl_reject_handshake on`, a conexão por IP cai nesse bloco antes de existir uma requisição HTTP capaz de selecionar `server_name PUBLIC_IP`.

O VPS Deployer precisa, portanto, ser o `default_server` TLS da porta 443 quando o endpoint público é o próprio IP.

Isso não impede os demais sites HTTPS: requisições com SNI válido continuam sendo encaminhadas aos blocos que possuem seus `server_name` específicos.

## Diagnóstico

```bash
sudo nginx -T 2>&1 | grep -nE \
  'listen .*443|default_server|ssl_reject_handshake|server_name'
```

Caso real observado:

```nginx
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}
```

Enquanto o VPS Deployer estava configurado apenas como:

```nginx
listen 443 ssl;
listen [::]:443 ssl;
server_name PUBLIC_IP;
```

## Correção segura

O objetivo é preservar o bloco antigo de rejeição, mas remover dele a função de `default_server`. O bloco do VPS Deployer assume essa função.

### 1. Faça backup dos dois arquivos

```bash
STAMP="$(date +%Y%m%d-%H%M%S)"

sudo cp -a /etc/nginx/sites-available/default \
  "/etc/nginx/sites-available/default.backup-$STAMP"

sudo cp -a /etc/nginx/sites-available/vps-deployer-ip.conf \
  "/etc/nginx/sites-available/vps-deployer-ip.conf.backup-$STAMP"
```

### 2. Retire `default_server` do bloco antigo

```bash
sudo sed -i \
  's/listen 443 ssl default_server;/listen 443 ssl;/' \
  /etc/nginx/sites-available/default

sudo sed -i \
  's/listen \[::\]:443 ssl default_server;/listen [::]:443 ssl;/' \
  /etc/nginx/sites-available/default
```

O `ssl_reject_handshake on` pode permanecer nesse bloco. Ele deixa apenas de ser o fallback TLS global.

### 3. Torne o VPS Deployer o default TLS

```bash
sudo sed -i \
  's/listen 443 ssl;/listen 443 ssl default_server;/' \
  /etc/nginx/sites-available/vps-deployer-ip.conf

sudo sed -i \
  's/listen \[::\]:443 ssl;/listen [::]:443 ssl default_server;/' \
  /etc/nginx/sites-available/vps-deployer-ip.conf
```

### 4. Valide antes de recarregar

```bash
sudo nginx -t
```

Não recarregue se o teste falhar. Use os backups criados no passo 1 para restaurar os arquivos.

### 5. Recarregue

```bash
sudo systemctl reload nginx
```

### 6. Valide o endpoint por IP

```bash
curl https://PUBLIC_IP/health
```

Resposta esperada:

```json
{"ok":true,"service":"vps-deployer","time":"..."}
```

### 7. Confirme que os sites existentes continuam válidos

Execute pelo menos:

```bash
sudo nginx -t
```

E valide externamente os domínios HTTPS já hospedados na VPS.

## Renovação do Certbot

Após migração APT -> Snap, o timer relevante é normalmente:

```text
snap.certbot.renew.timer
```

Confira:

```bash
systemctl list-timers --all | grep -Ei 'certbot|snap.certbot' || true
```

Um `certbot.timer` antigo pode aparecer como resíduo da instalação APT. Não remova esse resíduo antes de validar que `snap.certbot.renew.timer` está ativo e que `certbot renew --dry-run` continua saudável.

## Regra para instalações futuras

O template `nginx/vps-deployer-ip.conf.template` mantém o bloco HTTPS do VPS Deployer como `default_server`. O script `setup-ip-tls.sh` também detecta previamente um `default_server` existente com `ssl_reject_handshake on` e interrompe a instalação para evitar alterar silenciosamente uma VPS multi-site.
