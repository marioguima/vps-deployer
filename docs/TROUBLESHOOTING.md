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

### Caso real encontrado no bootstrap

Foi encontrado um servidor com:

```text
certbot 2.9.0
/usr/bin/certbot
```

instalado via APT, com os pacotes:

```text
certbot
python3-certbot
python3-certbot-nginx
```

e vários certificados já existentes em `/etc/letsencrypt/live`.

Nesse cenário **não remova nem reinstale Certbot antes de validar e fazer backup do estado existente**.

### 1. Descubra como o Certbot atual foi instalado

Execute:

```bash
certbot --version
command -v certbot
snap list certbot 2>/dev/null || true
dpkg -l | grep -E 'certbot|python3-certbot' || true
sudo ls -la /etc/letsencrypt/live 2>/dev/null || true
```

Se existirem certificados, prossiga pelo fluxo seguro abaixo.

### 2. Faça backup antes da migração

Guarde Certbot e Nginx antes de trocar pacotes:

```bash
STAMP="$(date +%Y%m%d-%H%M%S)"
sudo tar -C / -czf "$HOME/certbot-nginx-backup-$STAMP.tar.gz" \
  etc/letsencrypt \
  etc/nginx
sudo chown "$(id -u):$(id -g)" "$HOME/certbot-nginx-backup-$STAMP.tar.gz"
ls -lh "$HOME/certbot-nginx-backup-$STAMP.tar.gz"
```

Não continue se o arquivo de backup não tiver sido criado.

### 3. Tire uma linha de base antes de alterar o cliente

Liste os certificados conhecidos:

```bash
sudo certbot certificates
```

Valide o Nginx:

```bash
sudo nginx -t
```

E teste a renovação atual:

```bash
sudo certbot renew --dry-run
```

Se a renovação já falhar **antes** da migração, registre essa falha separadamente; não atribua automaticamente o problema ao upgrade.

### 4. Migre do pacote APT para o Snap oficial

O projeto Certbot recomenda Snap para a maioria dos usuários Linux e orienta remover os pacotes do sistema para evitar que o comando `certbot` continue chamando a versão antiga.

Confirme primeiro que `snap` existe:

```bash
snap version
```

Se `snap` não existir, instale/configure `snapd` conforme a documentação oficial da sua distribuição antes de continuar.

Com backup e linha de base concluídos:

```bash
sudo apt-get remove certbot python3-certbot python3-certbot-nginx
sudo snap install --classic certbot
sudo ln -s /snap/bin/certbot /usr/local/bin/certbot
```

Se o último comando disser que o link já existe, investigue antes de sobrescrever:

```bash
ls -l /usr/local/bin/certbot
```

Não use `rm -f` cegamente nesse caminho.

### 5. Valide imediatamente após a migração

O executável usado deve ser o novo Certbot e a versão precisa ser 5.4 ou superior:

```bash
certbot --version
command -v certbot
```

Confira se as lineages anteriores continuam reconhecidas:

```bash
sudo certbot certificates
```

Valide novamente Nginx e renovação:

```bash
sudo nginx -t
sudo certbot renew --dry-run
```

Só considere a migração concluída se os certificados existentes continuarem listados e o teste de renovação estiver saudável, ou se qualquer falha observada for a mesma que já existia na linha de base.

### 6. Confira renovação automática do Snap

```bash
systemctl list-timers --all | grep -i certbot || true
systemctl list-timers --all | grep -i snap.certbot || true
```

Certificados de IP do Let's Encrypt usam o perfil `shortlived`, portanto a renovação automática não é opcional.

### 7. Atualize o VPS Deployer e tente o IP TLS novamente

```bash
cd ~/vps-deployer
git pull
sudo ./scripts/install.sh
sudo vps-deployer-doctor
```

Depois:

```bash
sudo ./scripts/setup-ip-tls.sh PUBLIC_IP SEU_EMAIL
```

### Por que não usar simplesmente o Certbot 2.9 existente?

O suporte necessário para esse fluxo não existe nele. Certbot 5.3 introduziu `--ip-address` e 5.4 adicionou suporte do plugin `webroot` para emissão de certificados de IP. O script exige 5.4+ deliberadamente.

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
