# Nginx: HTTPS por IP literal em VPS com vários sites

Este runbook cobre o caso em que o certificado do IP público foi emitido corretamente, mas `curl https://PUBLIC_IP/health` falha durante o handshake TLS com erro semelhante a `tlsv1 unrecognized name`.

## Causa inicial encontrada

HTTPS por IP literal não deve depender de SNI para selecionar o virtual host. Em uma VPS multi-site foi encontrado um `listen 443 ssl default_server` com `ssl_reject_handshake on`, enquanto o bloco do VPS Deployer tinha apenas `server_name PUBLIC_IP`.

O bloco do VPS Deployer foi então promovido a `default_server` TLS e o bloco antigo deixou de ser default. Essa alteração passou em `nginx -t`, porém **não resolveu sozinha** o `curl https://PUBLIC_IP/health`.

Portanto, a troca do `default_server` é uma integração necessária para o acesso por IP, mas não deve ser tratada como diagnóstico final sem testar separadamente o caminho local e o caminho pelo IP público.

## Diagnóstico inicial

```bash
sudo nginx -T 2>&1 | grep -nE \
  'listen .*443|default_server|ssl_reject_handshake|server_name'
```

Caso real observado originalmente:

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

## Integração aplicada

O bloco antigo de rejeição foi preservado, mas deixou de ser `default_server`. O VPS Deployer passou a ser o default TLS:

```nginx
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name PUBLIC_IP;

    ssl_certificate /etc/letsencrypt/live/vps-deployer-ip/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/vps-deployer-ip/privkey.pem;
}
```

O bloco antigo permaneceu como:

```nginx
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name _;
    ssl_reject_handshake on;
}
```

A configuração foi validada com:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

Mesmo assim, o primeiro `curl https://PUBLIC_IP/health` continuou retornando `tlsv1 unrecognized name`.

## Teste que confirmou o default TLS local

Para separar seleção de virtual host de rota de rede, foi testado o Nginx localmente sem SNI:

```bash
echo | openssl s_client \
  -connect 127.0.0.1:443 \
  -noservername \
  -brief 2>&1
```

Resultado real:

```text
CONNECTION ESTABLISHED
Protocol version: TLSv1.3
Ciphersuite: TLS_AES_256_GCM_SHA384
Verification: OK
DONE
```

Isso confirma que:

- o listener TLS local está saudável;
- o `default_server` atual consegue completar o handshake sem SNI;
- o certificado é válido no caminho local;
- a falha restante não pode ser atribuída simplesmente ao bloco antigo ainda conter `ssl_reject_handshake on`.

## Próximo diagnóstico obrigatório: mesma conexão no IP público

O teste anterior usou `127.0.0.1`, enquanto o `curl` com falha usa o IP público. Antes de concluir que SNI é a única diferença, teste o mesmo handshake **sem SNI** no IP público:

```bash
echo | openssl s_client \
  -connect PUBLIC_IP:443 \
  -noservername \
  -brief 2>&1
```

Também elimine proxy de ambiente do `curl`:

```bash
curl --noproxy '*' -vk https://PUBLIC_IP/health
```

E confira se há variáveis de proxy:

```bash
env | grep -iE '^(http|https|all|no)_proxy=' || true
```

Interpretação:

- se `openssl ... PUBLIC_IP ... -noservername` funcionar, o caminho público chega corretamente ao Nginx e deve-se investigar comportamento do cliente/SNI ou proxy;
- se falhar enquanto `127.0.0.1` funciona, o problema está fora da seleção local do virtual host: rota, NAT, proxy, firewall, balanceador ou outro componente no caminho público;
- se `curl --noproxy '*'` funcionar e o `curl` comum falhar, a causa é um proxy de ambiente.

## Sobre SNI e IP literal

RFC 6066 define `HostName` do SNI como hostname DNS e proíbe IPv4/IPv6 literal. A documentação do Nginx também alerta que apenas nomes de domínio devem ser usados em SNI e que alguns clientes podem enviar IP por engano; não se deve depender desse comportamento.

Por isso, sempre compare explicitamente:

```bash
# sem SNI
echo | openssl s_client -connect PUBLIC_IP:443 -noservername -brief 2>&1

# SNI explícito apenas para diagnóstico
echo | openssl s_client -connect PUBLIC_IP:443 -servername PUBLIC_IP -brief 2>&1
```

O segundo comando serve somente para reproduzir o comportamento de um cliente que envie IP literal em SNI; não representa o uso recomendado pelo padrão.

## Renovação do Certbot

Após migração APT -> Snap, o timer relevante é:

```text
snap.certbot.renew.timer
```

Confira:

```bash
systemctl list-timers --all | grep -Ei 'certbot|snap.certbot' || true
```

Um `certbot.timer` antigo pode aparecer como resíduo da instalação APT. Não remova esse resíduo antes de validar que `snap.certbot.renew.timer` está ativo e que `certbot renew --dry-run` continua saudável.

## Regra para instalações futuras

O template `nginx/vps-deployer-ip.conf.template` mantém o bloco HTTPS do VPS Deployer como `default_server`. O script `setup-ip-tls.sh` detecta previamente um `default_server` existente com `ssl_reject_handshake on` e interrompe a instalação para evitar alterar silenciosamente uma VPS multi-site.

Em VPS multi-site, sempre valide separadamente:

1. `nginx -t`;
2. handshake local sem SNI em `127.0.0.1:443`;
3. handshake público sem SNI em `PUBLIC_IP:443`;
4. `curl --noproxy '*' https://PUBLIC_IP/health`;
5. domínios HTTPS já hospedados na VPS.
