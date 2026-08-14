# Migração VPS Deployer -> Coolify — 2026-08-14

## Decisão

O `vps-deployer` foi congelado como solução transitória. Depois que o TrackPixel estiver estável em homolog e produção pelo Coolify — incluindo o teste de transferência do repositório para uma organização — o `vps-deployer` deve ser removido sem preservar código por apego à implementação.

O motivo é evitar manter internamente funcionalidades que o Coolify já oferece: integração GitHub App, auto-deploy por branch, Docker Compose, histórico/status/logs de deploy e operação via painel.

## Estado real validado

Coolify foi instalado na VPS `sales-oci` usando a porta padrão `8000`.

Containers observados:

```text
coolify
coolify-db
coolify-redis
coolify-realtime
```

PostgreSQL, Redis e realtime estavam `healthy`; inicialmente apenas `coolify` estava `unhealthy`.

## Falha encontrada: `.env` inválido

Sintoma:

```text
The environment file is invalid!
Failed to parse dotenv file. Encountered unexpected whitespace at [Aa1EMAIL=admin@intellifyads.com(openssl rand -hex 20)].
```

Causa: durante uma tentativa inicial executada diretamente em shell interativo, uma senha contendo `!` sofreu expansão/interpretação pelo Bash e produziu uma linha inválida em `/data/coolify/source/.env`.

Não era conflito de porta. A porta `8000` já pertencia corretamente ao próprio container `coolify`.

## Recuperação

Foi criado `scripts/repair-coolify-env.sh` para:

- fazer backup do `.env` quebrado;
- remover apenas linhas `ROOT_*`/fragmentos corrompidos;
- gerar credenciais válidas sem depender de expansão de shell interativo;
- reiniciar somente o container `coolify`;
- executar o seeder do root user;
- validar o endpoint `/api/health`.

Resultado real:

```text
SUCCESS  Root user created successfully.
SUCCESS  Registration has been disabled successfully.
coolify_container_health=healthy
coolify_http_health=200
COOLIFY_ENV_REPAIR_OK
```

Credenciais locais ficam em:

```text
/root/coolify-admin.txt
```

Nunca registrar a senha real no Git/repositório.

## Falha encontrada: localhost não alcançável pelo Coolify

No onboarding, ao escolher `This machine`, o Coolify tentou gerenciar a própria VPS via SSH como `root` e exibiu `Server is not reachable`.

A instalação não tinha um arquivo `*.pub` separado em `/data/coolify/ssh/keys`, então procurar apenas por chave pública falhava. Foi criado `scripts/repair-coolify-localhost-ssh.sh`, que deriva a chave pública a partir da chave privada já gerenciada pelo Coolify, autoriza exatamente essa chave em `/root/.ssh/authorized_keys`, mantém login root restrito a chave (`without-password`/`prohibit-password`) e valida SSH local pela mesma identidade.

Resultado real:

```text
Authorized Coolify localhost public key derived from: ssh_key@9faccrkejmxtitt6aumw5wii
permitrootlogin=without-password
Warning: Permanently added '127.0.0.1' (ED25519) to the list of known hosts.
COOLIFY_LOCALHOST_SSH_OK
```

Isso valida a camada SSH necessária para o Coolify administrar `This machine` sem habilitar senha para root.

## TrackPixel homolog no Coolify

O recurso deve usar:

```text
GitHub App: git-hub--marioguima
Repository: marioguima/trackpixel
Branch: homolog
Build pack: Docker Compose
Base directory: /
Compose file: /docker-compose.yml
```

A extensão do Compose precisa bater exatamente com o arquivo no Git. O TrackPixel usa `docker-compose.yml` (não `docker-compose.yaml`). Se o caminho estiver como `/docker-compose.yaml`, o recurso é criado, mas o Coolify fica com `Load a Compose file to deploy` e a área de conteúdo Compose vazia. Corrija para `/docker-compose.yml` e então clique `Load compose` antes de configurar variáveis ou fazer deploy.

O `docker-compose.prod.yml` é apenas override de limites/logging e não é necessário para o primeiro deploy funcional no Coolify.

Variáveis de homolog foram importadas no recurso via `Environment Variables`, preservando os secrets já gerados anteriormente e configurando explicitamente:

```text
API_PORT=3100
PIXEL_PORT=3101
PUBLIC_TRACKING_BASE_URL=https://track-homolog.intellifyads.com
```

O primeiro deploy manual foi iniciado com sucesso pelo painel do Coolify para o commit `7420c75...` da branch `homolog`. O histórico/log de deployment passou a ser visível diretamente no dashboard. No momento do registro, o deployment estava `In progress` e já havia concluído a importação do repositório e iniciado a preparação/build do Docker Compose.

Esse ponto valida que a operação normal não precisa mais de `sudo vps-deployer-jobs` ou leitura de logs por SSH: acompanhamento, histórico e logs estão disponíveis no Coolify.

## Regra aprendida

Scripts com `set -e`, passwords com caracteres especiais e geração de secrets não devem ser colados como um bloco que altera o shell SSH interativo. Para operações destrutivas ou de bootstrap, usar um arquivo versionado executado como processo separado, por exemplo:

```bash
sudo bash ./scripts/nome-do-script.sh
```

Assim falhas retornam ao prompt e não encerram a sessão Termius.

## Próximos passos

1. Aguardar o primeiro deployment homolog concluir e validar `success`.
2. Validar containers, migrations e health checks.
3. Manter o Nginx atual responsável por 80/443 com proxy Coolify em `Custom` e apontá-lo para as portas de homolog.
4. Configurar endpoint HTTPS definitivo do Coolify/webhook antes de fechar as portas temporárias 8000/6001/6002.
5. Validar push em `homolog` -> auto-deploy no Coolify.
6. Repetir para produção (`main`).
7. Transferir o repositório para a organização e validar novamente.
8. Só então desativar/remover VPS Deployer, webhook/App antigos e infraestrutura transitória.
