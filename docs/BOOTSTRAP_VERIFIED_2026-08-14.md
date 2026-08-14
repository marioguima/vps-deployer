# Bootstrap verificado em 2026-08-14

Este registro documenta o primeiro bootstrap real validado do VPS Deployer em uma VPS existente.

## Resultado da instalação

- clone inicial por SSH falhou por ausência de chave GitHub na VPS;
- clone por HTTPS funcionou e passou a ser o caminho recomendado no bootstrap;
- `scripts/install.sh` instalou o serviço com sucesso;
- `vps-deployer-doctor` passou com zero mappings;
- `vps-deployer.service` ficou `active (running)`;
- `curl http://127.0.0.1:9100/health` retornou `ok: true`.

## Migração do Certbot necessária

A VPS possuía Certbot 2.9.0 instalado via APT e sete certificados Let's Encrypt existentes. O setup TLS por IP recusou continuar porque certificados de IP via `webroot` exigem Certbot 5.4+.

A sequência segura e reproduzível para diagnosticar, fazer backup, simular a remoção APT, migrar para Snap e validar os certificados está documentada em `docs/TROUBLESHOOTING.md`, na seção do erro `certbot >= 5.4 is required for webroot IP certificates`.

No bootstrap real:

- a simulação de remoção mostrou somente `certbot`, `python3-certbot` e `python3-certbot-nginx`;
- o backup de `/etc/letsencrypt` e `/etc/nginx` foi criado antes da migração;
- o Certbot foi migrado de APT 2.9.0 para Snap 5.7.0;
- `command -v certbot` passou a apontar para `/usr/local/bin/certbot`;
- `certbot --version` passou a retornar `certbot 5.7.0`;
- Nginx permaneceu válido;
- todos os certificados existentes passaram em `certbot renew --dry-run`.

Certificados validados:

```text
agoraentendi.com.br
angelicfortunes.com
app.agoraentendi.com.br
app.angelicfortunes.com
app.meninacomproposito.com.br
firaz.com.br
meninacomproposito.com.br
```

A saída final confirmou:

```text
Congratulations, all simulated renewals succeeded
```

Portanto, a migração do Certbot foi concluída sem regressão observada nos certificados existentes.

## Emissão do certificado do IP

Após a migração para Certbot 5.7.0, `scripts/setup-ip-tls.sh` foi executado para o IP público `136.248.109.197`.

Resultado observado:

- challenge HTTP e validação do Nginx concluíram com sucesso;
- o certificado para `136.248.109.197` foi emitido com sucesso;
- certificado salvo em `/etc/letsencrypt/live/vps-deployer-ip/fullchain.pem`;
- chave salva em `/etc/letsencrypt/live/vps-deployer-ip/privkey.pem`;
- validade informada até `2026-08-20`;
- o Certbot informou que configurou renovação automática;
- o script concluiu e publicou os endpoints esperados `https://136.248.109.197/github` e `https://136.248.109.197/health`.

## Renovação automática validada

A inspeção de timers mostrou:

```text
snap.certbot.renew.timer
```

com próxima execução agendada. Portanto, a instalação Snap possui renovação automática ativa.

Também permaneceu visível um `certbot.timer` antigo da instalação APT, sem próxima execução agendada. Esse timer legado deve ser tratado como resíduo e removido/desabilitado somente depois de confirmar sua origem; ele não substitui o timer `snap.certbot.renew.timer`.

## Falha no primeiro teste HTTPS por IP

O teste:

```bash
curl https://136.248.109.197/health
```

retornou:

```text
curl: (35) OpenSSL/3.0.13: error:0A000458:SSL routines::tlsv1 unrecognized name
```

O certificado já estava emitido; portanto a falha ocorre durante o handshake TLS, antes de a requisição HTTP chegar ao `vps-deployer`.

## Nginx multi-site encontrado

A inspeção confirmou um bloco de segurança existente em `/etc/nginx/sites-available/default`:

```nginx
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name _;
    ssl_reject_handshake on;
}
```

O bloco do VPS Deployer ficou configurado como:

```nginx
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name 136.248.109.197;
    ssl_certificate /etc/letsencrypt/live/vps-deployer-ip/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/vps-deployer-ip/privkey.pem;
}
```

Antes disso, o bloco de segurança era o `default_server`. Foi feito backup dos dois arquivos, removido `default_server` do bloco antigo e atribuído `default_server` ao bloco do VPS Deployer. `nginx -t` passou e o Nginx foi recarregado com sucesso.

**Importante:** essa alteração, embora sintaticamente correta e aplicada, **não resolveu** o `curl https://136.248.109.197/health`; o mesmo `tlsv1 unrecognized name` permaneceu. Portanto, não considerar a simples troca de `default_server` como solução final.

A documentação oficial do Nginx informa que conexões começam no contexto do servidor default e podem trocar de virtual server durante o handshake via SNI. Ela também alerta que somente nomes de domínio devem ser usados em SNI e que alguns clientes podem passar IP literal de forma não confiável. O próximo diagnóstico deve separar handshake sem SNI de handshake com IP usado como SNI.

## Próximo diagnóstico seguro

Sem alterar configuração, testar primeiro TLS sem SNI:

```bash
echo | openssl s_client \
  -connect 127.0.0.1:443 \
  -noservername \
  -brief 2>&1
```

Depois, apenas se necessário, comparar com um handshake forçando o IP como nome SNI:

```bash
echo | openssl s_client \
  -connect 127.0.0.1:443 \
  -servername 136.248.109.197 \
  -brief 2>&1
```

Interpretação:

- se `-noservername` funcionar e `-servername 136.248.109.197` falhar com `unrecognized name`, o problema está ligado à seleção via SNI/IP literal;
- se `-noservername` também falhar, ainda existe comportamento de TLS/default server a investigar na configuração ativa.

Não fazer novas alterações no Nginx até esse teste separar os dois casos.

## Regra para instalações futuras

Em uma VPS que já tenha um `default_server` TLS de segurança, o instalador do VPS Deployer não deve substituir comportamento existente silenciosamente. O script `setup-ip-tls.sh` foi endurecido para detectar `:443 default_server` combinado com `ssl_reject_handshake on` e parar para inspeção manual.

Este arquivo é um registro de validação. Para repetir o procedimento em outra VPS, use `docs/BOOTSTRAP.md` como roteiro principal e `docs/TROUBLESHOOTING.md` para os casos já encontrados.
