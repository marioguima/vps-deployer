# Troubleshooting

Problemas já encontrados durante o bootstrap real do VPS Deployer e como resolvê-los.

## `git clone git@github.com:...` falha com `Permission denied (publickey)`

Sintoma:

```text
git@github.com: Permission denied (publickey).
fatal: Could not read from remote repository.
```

Causa: a conta Linux da VPS ainda não possui uma chave SSH autorizada no GitHub.

Para instalar este deployer em uma VPS nova, use HTTPS:

```bash
cd ~
git clone https://github.com/marioguima/vps-deployer.git
cd vps-deployer
sudo ./scripts/install.sh
```

Não é necessário criar uma chave SSH apenas para o bootstrap do VPS Deployer.

Se o projeto a ser implantado for privado, o **script desse projeto** precisará posteriormente de uma estratégia de autenticação Git própria.

---

## Primeiro SSH para `github.com` pede confirmação de fingerprint

Sintoma:

```text
The authenticity of host 'github.com (...)' can't be established.
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

Isso é o `known_hosts` do SSH. Confirmar o host apenas registra a identidade do servidor GitHub; não cria uma credencial GitHub para a VPS.

Se após aceitar aparecer `Permission denied (publickey)`, use HTTPS para o bootstrap ou configure uma chave SSH explicitamente.

---

## `certbot >= 5.4 is required for webroot IP certificates`

O script `setup-ip-tls.sh` para antes de modificar o Nginx quando detecta Certbot anterior a 5.4.

Isso é intencional. Certbot 5.4+ é necessário para solicitar certificado de endereço IP usando o plugin `webroot`.

### 1. Descubra como o Certbot atual foi instalado

Execute:

```bash
certbot --version
command -v certbot
snap list certbot 2>/dev/null || true
dpkg -l | grep -E 'certbot|python3-certbot' || true
```

Guarde a saída antes de trocar pacotes. Em uma VPS que já hospeda outros serviços, `/etc/letsencrypt` pode conter certificados e configurações importantes.

### 2. Instalação moderna recomendada pelo projeto Certbot

A documentação oficial do Certbot recomenda Snap para a maioria dos usuários Linux. Ela também recomenda remover pacotes Certbot instalados pelo gerenciador da distribuição antes de instalar o Snap, para evitar que o comando `certbot` continue apontando para a versão antiga.

**Antes de remover qualquer pacote em uma VPS já usada, confira os comandos do passo 1 e faça backup de `/etc/letsencrypt` se houver certificados existentes.**

Fluxo típico em Ubuntu:

```bash
sudo cp -a /etc/letsencrypt /etc/letsencrypt.backup-before-certbot-upgrade 2>/dev/null || true
sudo apt-get remove certbot python3-certbot-nginx
sudo snap install --classic certbot
sudo ln -s /snap/bin/certbot /usr/local/bin/certbot
```

Se o link já existir:

```bash
ls -l /usr/local/bin/certbot
```

Não sobrescreva um caminho inesperado sem investigar.

Depois confirme:

```bash
certbot --version
command -v certbot
```

É necessário 5.4 ou superior.

> Não execute cegamente a remoção acima em um servidor com setup Certbot personalizado. Primeiro verifique a instalação existente. O objetivo é preservar `/etc/letsencrypt` e substituir apenas o cliente antigo.

### 3. Confira renovação automática

Instalações Snap normalmente incluem o mecanismo de renovação. Confira:

```bash
systemctl list-timers --all | grep -i certbot || true
systemctl list-timers --all | grep -i snap.certbot || true
```

Certificados de IP do Let's Encrypt usam o perfil `shortlived`, portanto a renovação automática não é opcional.

### 4. Atualize sua cópia do VPS Deployer antes de tentar novamente

Se este repositório recebeu correções após o primeiro erro:

```bash
cd ~/vps-deployer
git pull
sudo ./scripts/install.sh
```

Depois:

```bash
sudo ./scripts/setup-ip-tls.sh PUBLIC_IP SEU_EMAIL
```

---

## Serviço sobe, mas `/health` local não responde

Confira:

```bash
sudo systemctl status vps-deployer --no-pager
sudo journalctl -u vps-deployer -n 100 --no-pager
sudo ss -ltnp | grep 9100
```

O estado esperado atrás do Nginx é um listener em `127.0.0.1:9100`, não `0.0.0.0:9100`.

---

## `/health` funciona localmente, mas não pelo IP público

Separe o diagnóstico em camadas:

```text
vps-deployer local → Nginx local → firewall da VPS → security list/cloud firewall → internet
```

Valide primeiro:

```bash
curl http://127.0.0.1:9100/health
sudo nginx -t
sudo ss -ltnp | grep -E ':80|:443'
```

Depois confira firewall local e regras de rede do provedor para TCP 80/443.

Não abra 9100 como primeira tentativa de correção; o desenho normal mantém essa porta privada.

---

## Onde olhar logs

Receiver/worker:

```bash
sudo journalctl -u vps-deployer -f
```

Jobs:

```bash
sudo vps-deployer-jobs
```

Log de um job específico:

```bash
sudo less /var/log/vps-deployer/job-ID.log
```

## Regra para novos problemas encontrados em produção

Quando um problema novo exigir um procedimento não óbvio para recuperar o deployer, registre a solução neste arquivo. O objetivo é que uma VPS possa ser reconstruída sem depender da memória de quem configurou a anterior.