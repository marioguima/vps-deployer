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

O primeiro teste:

```bash
curl https://136.248.109.197/health
```

retornou:

```text
curl: (35) OpenSSL/3.0.13: error:0A000458:SSL routines::tlsv1 unrecognized name
```

O certificado já estava emitido; portanto a falha ocorria durante a seleção do virtual host TLS no Nginx, antes de a requisição HTTP chegar ao `vps-deployer`.

## Causa confirmada no Nginx

A inspeção com `nginx -T` confirmou dois blocos relevantes:

```text
listen 443 ssl default_server;
listen [::]:443 ssl default_server;
server_name _;
ssl_reject_handshake on;
```

E, separadamente, o bloco criado para o deployer:

```text
server_name 136.248.109.197;
listen 443 ssl;
listen [::]:443 ssl;
```

Isso confirma a causa: requisições TLS para um IP literal não podem depender de SNI para selecionar o bloco `server_name 136.248.109.197`. IPv4/IPv6 literal não é permitido como `HostName` do SNI pelo RFC 6066. A conexão começa no `default_server` de `:443`, que nesta VPS está configurado para rejeitar o handshake com `ssl_reject_handshake on`.

O comportamento é consistente com a documentação do Nginx: `ssl_reject_handshake on` rejeita o handshake do bloco, e a seleção inicial do virtual server TLS ocorre no contexto do servidor default, podendo mudar por SNI quando há um nome DNS válido.

## Regra para VPS multi-site

Em uma VPS que já tenha um `default_server` TLS de segurança, o instalador do VPS Deployer **não deve substituí-lo automaticamente**. Primeiro é necessário localizar o arquivo que contém o `ssl_reject_handshake on` e decidir conscientemente como integrar o endpoint do IP.

O script `setup-ip-tls.sh` foi endurecido para detectar a combinação de `:443 default_server` + `ssl_reject_handshake on` antes de emitir/configurar TLS em instalações futuras. Ele agora para e pede inspeção manual, evitando que o problema só apareça após a emissão do certificado.

Para localizar o arquivo real na VPS:

```bash
sudo grep -R -n -B 8 -A 8 'ssl_reject_handshake on' \
  /etc/nginx/sites-available /etc/nginx/conf.d 2>/dev/null
```

Não alterar ou remover o bloco default às cegas: esta VPS hospeda vários domínios HTTPS.

## Próxima etapa

Localizar o arquivo do `default_server` TLS atual e adaptar esse bloco de forma que conexões sem SNI para o IP público recebam o certificado `vps-deployer-ip` e exponham somente `/github` e `/health`, preservando o comportamento dos domínios existentes.

Depois validar:

```bash
sudo nginx -t
curl https://136.248.109.197/health
```

Este arquivo é um registro de validação. Para repetir o procedimento em outra VPS, use `docs/BOOTSTRAP.md` como roteiro principal e `docs/TROUBLESHOOTING.md` para os casos já encontrados.
