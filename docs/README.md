# Índice da documentação

Use este índice para reconstruir ou entender o VPS Deployer sem depender de memória do projeto.

## Comece aqui

- [BOOTSTRAP.md](BOOTSTRAP.md) — instalação/reconstrução da VPS.
- [BOOTSTRAP_VERIFIED_2026-08-14.md](BOOTSTRAP_VERIFIED_2026-08-14.md) — registro do primeiro bootstrap real validado.
- [DEPLOY_ARCHITECTURE_FOR_BEGINNERS.md](DEPLOY_ARCHITECTURE_FOR_BEGINNERS.md) — explicação simples de webhook, GitHub App e SHA.
- [DEPLOY_PIPELINE_CONTRACT.md](DEPLOY_PIPELINE_CONTRACT.md) — contrato da esteira: push em homolog/main deve concluir o deploy sem operação manual.
- [PROJECT_MANIFEST.md](PROJECT_MANIFEST.md) — estratégia genérica de publicação usando `host + base_path` para raiz, `/hml` ou subdomínio.
- [GITHUB_APP_SETUP.md](GITHUB_APP_SETUP.md) — criação, permissões, instalação e armazenamento da GitHub App.
- [COOLIFY_MIGRATION_2026-08-14.md](COOLIFY_MIGRATION_2026-08-14.md) — decisão de migrar para Coolify, instalação, recuperação do `.env` e plano de retirada do VPS Deployer.

## Operação e segurança

- [SECURITY.md](SECURITY.md) — decisões e limites de segurança.
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — problemas reais encontrados e correções.
- [NGINX_RAW_IP_TLS.md](NGINX_RAW_IP_TLS.md) — HTTPS por IP em VPS multi-site.

## Validações de projetos

- [GITHUB_APP_VALIDATION_2026-08-14.md](GITHUB_APP_VALIDATION_2026-08-14.md) — validação real de JWT, installation token e Git privado.
- [TRACKPIXEL_SMOKE_TEST.md](TRACKPIXEL_SMOKE_TEST.md) — smoke test real do fluxo GitHub push -> webhook -> fila -> worker.
- [TRACKPIXEL_AUTOMATED_PIPELINE.md](TRACKPIXEL_AUTOMATED_PIPELINE.md) — onboarding, primeiro deploy real e transferência para organização preservando o workspace.
