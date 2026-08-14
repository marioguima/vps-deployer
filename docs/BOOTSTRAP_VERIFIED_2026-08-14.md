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

## Próxima etapa

Com Certbot 5.7.0 validado, o bootstrap pode retomar a etapa HTTPS por IP descrita em `docs/BOOTSTRAP.md`: atualizar o clone local e executar `scripts/setup-ip-tls.sh` para o IP público, mantendo o receiver Python restrito a `127.0.0.1:9100`.

Este arquivo é um registro de validação. Para repetir o procedimento em outra VPS, use `docs/BOOTSTRAP.md` como roteiro principal e `docs/TROUBLESHOOTING.md` para a migração segura do Certbot quando necessária.
