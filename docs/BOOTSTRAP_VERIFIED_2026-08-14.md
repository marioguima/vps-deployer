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

O script também exibiu:

```text
WARNING: no Certbot renewal timer detected. Configure automatic renewal before relying on IP TLS.
```

Essa divergência entre a mensagem do Certbot e a detecção do script deve ser validada antes de considerar o bootstrap encerrado.

## Falha no primeiro teste HTTPS por IP

O primeiro teste:

```bash
curl https://136.248.109.197/health
```

retornou:

```text
curl: (35) OpenSSL/3.0.13: error:0A000458:SSL routines::tlsv1 unrecognized name
```

O certificado já estava emitido; portanto essa falha ocorre durante a seleção do virtual host TLS no Nginx, antes de a requisição HTTP chegar ao `vps-deployer`.

Em uma VPS que hospeda vários sites HTTPS, conexões feitas por IP literal não devem depender de SNI para selecionar o bloco correto. RFC 6066 não permite IPv4/IPv6 literal no campo `HostName` do SNI, e a própria documentação do Nginx recomenda não confiar nisso. É necessário verificar o `default_server` de `:443` e qualquer uso de `ssl_reject_handshake` antes de alterar a configuração existente.

Diagnóstico a ser executado antes de qualquer correção:

```bash
sudo nginx -T 2>&1 | grep -nE 'listen .*443|default_server|ssl_reject_handshake|server_name'
sudo ss -ltnp | grep ':443'
```

Não substituir ou remover o `default_server` existente às cegas, porque esta VPS já hospeda outros domínios HTTPS.

## Próxima etapa

Confirmar qual bloco Nginx recebe conexões TLS sem SNI em `:443`, corrigir a seleção do certificado para acesso por IP sem interromper os domínios existentes e validar:

```bash
curl https://136.248.109.197/health
```

Depois, validar separadamente o mecanismo de renovação automática do certificado curto de IP.

Este arquivo é um registro de validação. Para repetir o procedimento em outra VPS, use `docs/BOOTSTRAP.md` como roteiro principal e `docs/TROUBLESHOOTING.md` para os casos já encontrados.
