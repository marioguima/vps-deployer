# Contrato da esteira automática de deploy

Este documento define o comportamento final esperado do VPS Deployer.

## Regra principal

Depois que um projeto estiver cadastrado uma única vez, o operador **não deve precisar entrar na VPS para fazer deploy**.

O único gatilho normal é um `git push` para uma branch autorizada.

```text
git push
   |
   v
GitHub webhook
   |
   v
VPS Deployer
   |
   +--> valida assinatura + repository + branch
   +--> resolve o project_id local autorizado
   +--> coloca job na fila
   +--> autentica no GitHub com GitHub App
   +--> busca exatamente o SHA recebido pelo webhook
   +--> executa o adaptador de deploy autorizado
   +--> atualiza containers/arquivos
   +--> publica de acordo com host + base_path do ambiente
   +--> valida health check
   +--> registra sucesso/falha no histórico
```

Não faz parte do fluxo normal:

- SSH manual;
- copiar arquivos com SCP/SFTP;
- gerar token manualmente;
- executar `git pull` manualmente;
- executar Docker manualmente;
- editar Nginx a cada deploy;
- GitHub Actions;
- `OCI_SSH_KEY`.

Os comandos manuais usados durante o bootstrap existem apenas para instalar e validar a infraestrutura.

---

## Identidade do projeto x localização do repositório

O VPS Deployer separa a identidade interna estável do projeto da localização atual no GitHub.

Durante o onboarding é gerado um identificador local imutável:

```text
project_id = <repo-name>--<12-hex-gerados>
```

Exemplo:

```text
trackpixel--7d2c9a41e6bf
```

Esse valor é gerado pela infraestrutura, fica na allowlist local e nunca vem do webhook ou do manifesto versionado.

A estrutura física deriva dele:

```text
/var/lib/vps-deployer/workspaces/<project_id>/homolog
/var/lib/vps-deployer/workspaces/<project_id>/production
```

A localização GitHub é uma propriedade separada:

```text
repository = marioguima/trackpixel
```

Se o repositório for transferido para uma organização:

```text
repository = empresa/trackpixel
```

muda a autorização/localização GitHub, mas o `project_id` e o workspace não mudam.

Isso também evita colisões entre repositórios com o mesmo nome pertencentes a owners diferentes.

---

## Contrato de branches e ambientes

```text
branch homolog -> ambiente homolog
branch main    -> ambiente production
```

A branch identifica o ambiente. **A branch não define a URL pública.**

A mesma versão identificada pelo SHA recebido no webhook deve ser a versão efetivamente implantada. O deploy não deve simplesmente pegar "o último commit disponível" depois que o job começou.

---

## Como um ambiente é publicado

A forma pública é configuração do projeto.

Internamente qualquer caso é normalizado como:

```text
host + base_path
```

Isso cobre os três modos que usamos conceitualmente:

```text
produção na raiz:
  host=example.com
  base_path=/

homolog por path:
  host=example.com
  base_path=/hml

homolog por hostname/subdomínio:
  host=homolog.example.com
  base_path=/
```

Portanto, `/hml` **não é regra universal** e subdomínio também não.

### Páginas de venda / sites simples

Padrão recomendado quando o projeto suporta path prefix:

```text
homolog    -> https://firaz.com.br/hml/nome-da-pagina
production -> https://firaz.com.br/nome-da-pagina
```

### Aplicações, APIs e serviços

Padrão recomendado quando é melhor isolar a origem:

```text
homolog    -> https://api-homolog.example.com/
production -> https://api.example.com/
```

TrackPixel permanece nesse segundo grupo.

Consulte `docs/PROJECT_MANIFEST.md`.

---

## Manifesto versionado do projeto

Domínio, base path e outras informações **não secretas** devem ser declarativas e versionadas junto ao projeto sempre que possível.

Formato planejado:

```text
.vps-deployer.json
```

Exemplos de informação não secreta:

```text
branch
host
base_path
health-check path
configuração pública de build/deploy
```

O `project_id` não pertence ao manifesto versionado; ele é identidade local da infraestrutura.

Segredos não pertencem ao repositório:

```text
senhas
tokens
private keys
webhook secret
chaves de criptografia
credenciais de banco
```

Esses valores permanecem protegidos na VPS.

---

## Segurança: autorização continua local

A GitHub App pode ter permissão para **ler** muitos repositórios de uma organização. Isso não significa que todos podem executar deploy.

A autorização continua sendo explícita no VPS Deployer:

```text
project_id + repository + branch -> adaptador autorizado
```

O `/etc/vps-deployer/projects.json` é a allowlist local.

Portanto:

```text
GitHub App access != deploy authorization
manifesto no repo   != deploy authorization
```

O payload do webhook nunca fornece `project_id` confiável nem comando shell livre.

---

## Componentes internos automáticos

### Webhook

Responsabilidade:

```text
GitHub -> VPS
```

Avisa que ocorreu um push e fornece repository, branch e SHA.

### GitHub App

Responsabilidade:

```text
VPS -> GitHub
```

Gera autenticação temporária para buscar repositórios privados.

### SHA

Responsabilidade:

```text
identificar a versão exata
```

O deploy deve fazer checkout do SHA completo recebido no webhook.

### `vps-deployer-git`

Helper interno instalado em:

```text
/usr/local/bin/vps-deployer-git
```

Ele:

1. lê Client ID e caminho da private key;
2. gera JWT curto;
3. localiza a instalação da App para `owner/repo`;
4. emite installation access token temporário;
5. usa `GIT_ASKPASS` para autenticar Git;
6. não coloca o token na URL do remote nem na linha de comando.

O operador não executa esse helper no fluxo diário.

### `vps-deployer-checkout`

Helper interno instalado em:

```text
/usr/local/bin/vps-deployer-checkout
```

Ele recebe do worker:

```text
DEPLOY_REPOSITORY
DEPLOY_BRANCH
DEPLOY_SHA
```

Inicializa/atualiza um working tree limpo, faz fetch autenticado e termina somente se `HEAD` for exatamente o SHA completo recebido pelo webhook.

Ele também define seu próprio diretório de trabalho e não depende do CWD herdado de `/home/ubuntu`.

### Adaptador de projeto

Cada projeto pode precisar de uma estratégia diferente:

```text
arquivos estáticos
Docker Compose
Node.js
serviço systemd
monorepo
```

O VPS Deployer seleciona um adaptador previamente autorizado. O adaptador interpreta o manifesto versionado e somente aplica formas de publicação que ele suporta.

---

## TrackPixel e o workflow legado

O workflow existente do TrackPixel já implementa dois ambientes por branch:

```text
main    -> production
homolog -> homolog
```

O roteamento atual é por hostnames separados:

```text
production:
  https://track.intellifyads.com
  https://pixel.intellifyads.com

homolog:
  https://track-homolog.intellifyads.com
  https://pixel-homolog.intellifyads.com
```

O novo VPS Deployer deve preservar esse desenho inicialmente.

O workflow legado:

1. faz checkout no runner do GitHub;
2. envia código por SCP;
3. na VPS executa `docker compose build`;
4. sobe Postgres e Redis;
5. executa migrations;
6. sobe API, worker e pixel;
7. configura Nginx/TLS;
8. executa health checks.

A substituição arquitetural é:

```text
GitHub Actions checkout + SCP + SSH
              |
              v
webhook + GitHub App + checkout do SHA na própria VPS
```

Build, migrations, containers, Nginx e health checks continuam responsabilidade do adaptador TrackPixel.

---

## Resultado esperado no uso diário

Para um projeto já configurado:

```bash
git push origin homolog
```

é suficiente para iniciar e concluir homologação.

E:

```bash
git push origin main
```

é suficiente para iniciar e concluir produção.

O operador não escolhe `/hml`, hostname, token ou comando no momento do push. Isso já está configurado.

---

## Sequência de implementação atual

Estado em 2026-08-14:

```text
[OK] webhook público HTTPS
[OK] assinatura HMAC
[OK] allowlist repository + branch
[OK] fila SQLite
[OK] worker serial
[OK] smoke test de push real
[OK] GitHub App criada
[OK] private key protegida na VPS
[OK] JWT da GitHub App
[OK] localizar instalação do TrackPixel
[OK] emitir installation access token
[OK] git ls-remote no TrackPixel privado
[OK] helper permanente vps-deployer-git implementado
[OK] helper de checkout exato do SHA implementado
[OK] modelo host + base_path documentado
[OK] nova versão instalada e testes executados na VPS
[OK] checkout real do SHA exato do TrackPixel validado na VPS
[OK] identidade local collision-safe definida: <repo>--<12hex>

[NEXT] incorporar project_id à allowlist/runtime
[NEXT] adaptador de deploy TrackPixel
[NEXT] manifesto do TrackPixel
[NEXT] cadastrar homolog e main
[NEXT] primeiro deploy real de homolog
[NEXT] validar Nginx/TLS/health checks
[NEXT] deploy de production
[NEXT] desativar workflow GitHub Actions
[NEXT] remover OCI_SSH_KEY legado
```
