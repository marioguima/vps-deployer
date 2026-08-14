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

A sequência segura e reproduzível para diagnosticar, fazer backup, simular a remoção APT, migrar para Snap e validar os certificados está documentada em `docs/TROUBLESHOOTING.md`.

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

## Emissão do certificado do IP

Após a migração para Certbot 5.7.0, `scripts/setup-ip-tls.sh` foi executado para o IP público `136.248.109.197`.

Resultado:

- certificado emitido com sucesso;
- certificado em `/etc/letsencrypt/live/vps-deployer-ip/fullchain.pem`;
- chave em `/etc/letsencrypt/live/vps-deployer-ip/privkey.pem`;
- validade inicial até `2026-08-20`;
- endpoint esperado: `https://136.248.109.197/github`;
- health: `https://136.248.109.197/health`.

## Renovação automática

A inspeção mostrou `snap.certbot.renew.timer` ativo e com próxima execução agendada. O `certbot.timer` antigo da instalação APT permaneceu visível sem próxima execução e deve ser tratado apenas como resíduo legado depois de toda a validação.

## Nginx multi-site e `default_server`

A VPS já possuía em `/etc/nginx/sites-available/default` um bloco TLS de segurança com:

```nginx
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name _;
    ssl_reject_handshake on;
}
```

Antes da integração, esse bloco era o `default_server`. Foram feitos backups e o bloco do VPS Deployer passou a ser o default TLS:

```nginx
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name 136.248.109.197;

    ssl_certificate /etc/letsencrypt/live/vps-deployer-ip/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/vps-deployer-ip/privkey.pem;
}
```

`nginx -t` passou e o serviço foi recarregado normalmente.

## Diagnóstico do primeiro erro TLS

Um primeiro teste simples:

```bash
curl https://136.248.109.197/health
```

retornou:

```text
curl: (35) OpenSSL/3.0.13: error:0A000458:SSL routines::tlsv1 unrecognized name
```

Isso levou à investigação de SNI/default server. Os testes seguintes mostraram que o Nginx e o certificado estavam corretos.

### TLS sem SNI pelo loopback

```bash
echo | openssl s_client \
  -connect 127.0.0.1:443 \
  -noservername \
  -brief 2>&1
```

Resultado:

```text
CONNECTION ESTABLISHED
Protocol version: TLSv1.3
Verification: OK
```

### TLS sem SNI pelo IP público

```bash
echo | openssl s_client \
  -connect 136.248.109.197:443 \
  -noservername \
  -brief 2>&1
```

Também concluiu TLS 1.3 com `Verification: OK`.

### Acesso HTTP direto ignorando proxies

O teste:

```bash
curl --noproxy '*' -vk https://136.248.109.197/health
```

retornou:

```text
HTTP/1.1 200 OK
{"ok":true,"service":"vps-deployer","time":"..."}
```

A validação final, sem `-k`, também passou:

```bash
curl --noproxy '*' https://136.248.109.197/health
```

Resultado real:

```json
{"ok":true,"service":"vps-deployer","time":"2026-08-14T09:26:09+00:00"}
```

Portanto, a cadeia abaixo está validada com certificado confiável e resposta HTTP 200:

```text
cliente -> IP público:443 -> TLS -> Nginx -> 127.0.0.1:9100 -> vps-deployer
```

### Proxy de ambiente não encontrado

Foi verificado:

```bash
env | grep -iE '^(http|https|all|no)_proxy=' || true
```

Nenhuma variável `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` ou `NO_PROXY` estava definida.

Consequentemente, **não registrar como causa confirmada que o primeiro erro vinha de variável de proxy**. O fato de `--noproxy '*'` ter funcionado mostra apenas que o acesso direto está saudável. Se o `curl` simples voltar a falhar em uma instalação futura, investigar também:

```text
~/.curlrc
/etc/curlrc
configuração local do curl
caminho/intermediário de rede
```

O primeiro erro pode ainda ter sido transitório durante a mudança/reload da configuração Nginx. A causa exata daquele primeiro `curl` não foi comprovada.

> O `-k` foi usado apenas durante diagnóstico. O teste final de produção passou sem `-k`.

## Estado final desta etapa

HTTPS por IP está concluído e validado. Os endpoints públicos estão prontos para a etapa de integração com GitHub:

```text
https://136.248.109.197/health
https://136.248.109.197/github
```

## Regra para instalações futuras

1. validar `/health` local em `127.0.0.1:9100`;
2. emitir/configurar TLS;
3. validar Nginx com `nginx -t`;
4. testar TLS pelo IP com `openssl s_client -noservername`;
5. testar HTTP direto com `curl --noproxy '*'` antes de alterar novamente o Nginx;
6. confirmar o certificado com o mesmo comando sem `-k`;
7. se o curl normal falhar mas `--noproxy '*'` funcionar, investigar ambiente/configuração do curl sem assumir a causa;
8. somente depois configurar os webhooks do GitHub.

Este arquivo é um registro de validação. Para repetir o procedimento em outra VPS, use `docs/BOOTSTRAP.md` como roteiro principal e `docs/TROUBLESHOOTING.md` para os casos já encontrados.
