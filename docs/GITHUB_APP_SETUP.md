# GitHub App do VPS Deployer

Este runbook cria a identidade usada pela VPS para ler repositórios privados no GitHub.

A GitHub App **não substitui o webhook**. Neste projeto:

```text
Webhook    = GitHub -> VPS: avisa que houve push e informa o SHA
GitHub App = VPS -> GitHub: autentica para buscar o código privado
SHA        = identifica exatamente qual commit deve ser implantado
```

Consulte também `docs/DEPLOY_ARCHITECTURE_FOR_BEGINNERS.md`.

---

## Objetivo

Ter **uma única GitHub App** que possa ser instalada:

- na conta pessoal que hoje possui o TrackPixel;
- em futuras organizações;
- com acesso de leitura aos repositórios;
- sem senha pessoal, PAT permanente ou Deploy Key por projeto.

Quando instalada em uma organização com `All repositories`, novos repositórios dessa organização passam a ficar disponíveis para a App sem cadastrar uma nova chave por projeto.

A autorização de deploy continua separada no `/etc/vps-deployer/projects.json`.

---

## 1. Criar a GitHub App

No GitHub:

```text
foto do perfil
-> Settings
-> Developer settings
-> GitHub Apps
-> New GitHub App
```

### Campos recomendados

#### GitHub App name

Use um nome globalmente único. Nome validado na instalação real:

```text
marioguima-vps-deployer
```

Nomes de GitHub Apps precisam ser únicos no GitHub; `VPS Deployer` já estava ocupado durante o primeiro bootstrap.

#### Description

```text
Acesso somente leitura usado pelo VPS Deployer para buscar código de repositórios privados em deploys disparados por webhook.
```

#### Homepage URL

Enquanto não existir uma página própria, use o repositório do projeto:

```text
https://github.com/marioguima/vps-deployer
```

#### Identifying and authorizing users

Não precisamos de login de usuário/OAuth para este caso.

Não configure callback URL.

#### Post installation

Não é necessário para este fluxo.

#### Webhook

**Desmarque `Active`.**

O VPS Deployer já possui webhooks independentes de repositório/organização em:

```text
https://PUBLIC_IP/github
```

Ativar webhook também na GitHub App criaria uma segunda fonte de eventos sem necessidade.

---

## 2. Permissões

Em **Repository permissions**, deixe tudo como `No access`, exceto:

```text
Contents: Read-only
```

O GitHub concede/usa acesso de leitura a Metadata conforme necessário para a App.

Não conceder para este caso:

```text
Administration
Actions
Checks
Deployments
Issues
Pull requests
Secrets
Workflows
Contents: Read & write
```

Princípio: a App só precisa conseguir fazer `git fetch/clone` dos repositórios privados.

---

## 3. Onde a App pode ser instalada

Em:

```text
Where can this GitHub App be installed?
```

selecione:

```text
Any account
```

### Por quê

`Only on this account` impediria usar a mesma App em futuras organizações diferentes da conta proprietária.

`Any account` permite instalar a mesma App na conta pessoal e nas organizações que controlamos.

Isso torna o registro da App público/instalável por outras contas, mas **não concede a terceiros acesso aos nossos repositórios**. Cada instalação só recebe acesso aos recursos da conta que aprovou aquela instalação, limitado pelas permissões da App.

Não é necessário publicar a App no GitHub Marketplace.

Clique:

```text
Create GitHub App
```

---

## 4. Anotar Client ID e App ID

Na página da App, localize:

```text
Client ID
App ID
```

O JWT aceita o Client ID ou o App ID no claim `iss`. A documentação atual do GitHub recomenda usar o **Client ID**.

O App ID continua útil como identificação e para diagnóstico.

Instalação validada em 2026-08-14:

```text
GitHub App: marioguima-vps-deployer
App ID:     4592846
```

> Atenção: durante o primeiro bootstrap foi digitado incorretamente `4592046`. Isso gerou `HTTP 404` com `message=Integration not found` em todos os endpoints autenticados como App. Um teste usando o Client ID retornou `GET /app -> HTTP 200` e revelou o App ID correto `4592846`.

Não confundir Client ID com Client Secret. **Client Secret não é necessário neste fluxo.**

---

## 5. Gerar a private key da App

Na própria página da GitHub App:

```text
Private keys
-> Generate a private key
```

O GitHub baixa um arquivo `.pem` no computador.

Essa chave é um segredo de alta sensibilidade:

- não fazer commit;
- não colocar em `projects.json`;
- não colocar dentro do TrackPixel;
- não enviar em chat;
- depois de copiar para a VPS, remover cópias temporárias desnecessárias.

O GitHub mantém apenas a parte pública; a private key precisa ser armazenada com segurança por nós.

---

## 6. Instalar a App na conta pessoal para o primeiro teste

Na configuração da App:

```text
Install App
```

Instale na conta pessoal que possui:

```text
marioguima/trackpixel
```

Para o primeiro teste, use o menor escopo possível:

```text
Only select repositories
-> trackpixel
```

Depois, quando o projeto estiver em uma organização, instale a mesma App nessa organização.

### Nas organizações futuras

Para atingir o objetivo de configuração mínima de novos projetos, a instalação da organização pode usar:

```text
All repositories
```

Assim novos repositórios da organização ficam automaticamente acessíveis à App.

Isso **não** autoriza deploy automático: o `/etc/vps-deployer/projects.json` continua sendo a allowlist local.

---

## 7. Copiar e proteger a private key na VPS

No primeiro bootstrap real, o upload foi feito por SFTP usando Termius para:

```text
/home/ubuntu/vps-deployer-github-app.pem
```

Depois a chave foi instalada no local definitivo:

```bash
sudo install \
  -o root \
  -g vps-deployer \
  -m 0640 \
  /home/ubuntu/vps-deployer-github-app.pem \
  /etc/vps-deployer/github-app.pem

rm -f /home/ubuntu/vps-deployer-github-app.pem
```

Configuração recomendada no `/etc/vps-deployer/env`:

```env
GITHUB_APP_CLIENT_ID=<Client ID exibido na página da App>
GITHUB_APP_ID=4592846
GITHUB_APP_PRIVATE_KEY=/etc/vps-deployer/github-app.pem
```

Para assinar o JWT, o helper deve preferir `GITHUB_APP_CLIENT_ID`.

Validação real da chave concluída:

```text
-rw-r----- 1 root vps-deployer ... /etc/vps-deployer/github-app.pem
OK: vps-deployer consegue ler a chave
GITHUB_APP_PRIVATE_KEY=/etc/vps-deployer/github-app.pem
```

Nunca usar `cat` para exibir a private key em logs ou chat.

---

## 8. Como a autenticação funcionará

O fluxo do código será:

```text
1. VPS lê Client ID + private key
2. gera um JWT curto assinado pela private key
3. identifica a instalação que tem acesso ao repositório
4. solicita um installation access token
5. token temporário autentica Git via HTTPS
6. git fetch
7. checkout exato de DEPLOY_SHA
8. token é descartado/expira
```

O JWT é assinado com RS256, deve ter duração de no máximo 10 minutos e o `iat` pode ser deslocado 60 segundos para trás para tolerar clock drift.

Installation access tokens do GitHub App expiram após aproximadamente uma hora e devem ser gerados novamente quando necessário.

Para Git via HTTPS, a permissão `Contents` é a permissão necessária para a App ler o conteúdo do repositório.

O token não deve ser persistido em arquivo, URL de remote ou log. O helper do deployer deve mantê-lo apenas em memória/ambiente temporário e usar um mecanismo como `GIT_ASKPASS` para autenticar o Git sem colocar o token na linha de comando.

### Validação real da identidade da App

Em 2026-08-14 foi gerado um JWT usando o Client ID da App e a private key já instalada na VPS.

Resultado:

```text
App -> HTTP 200
name=marioguima-vps-deployer
slug=marioguima-vps-deployer
id=4592846
message=
```

Isso comprova:

- private key correta e legível pelo usuário `vps-deployer`;
- assinatura RS256 válida;
- Client ID correto;
- GitHub reconhecendo a identidade da App.

Ainda falta validar a segunda etapa: descobrir a instalação do `marioguima/trackpixel`, emitir o installation access token e autenticar o Git.

---

## 9. Próximos passos depois de criar a App

Não fazer deploy real imediatamente.

A sequência segura será:

```text
A. criar App                                  VALIDADO
B. instalar App em marioguima/trackpixel     VALIDADO
C. gerar private key PEM                     VALIDADO
D. copiar PEM com segurança para a VPS       VALIDADO
E. validar identidade/JWT da App             VALIDADO
F. corrigir App ID e salvar Client ID na VPS PRÓXIMO
G. emitir installation access token
H. testar autenticação read-only com TrackPixel
I. testar git fetch sem alterar /opt/intellifyads
J. criar clone/working tree de homolog
K. checkout exato do SHA recebido pelo webhook
L. somente então executar Docker/build/migrate/up
M. validar homolog
N. aposentar workflow legado
O. remover OCI_SSH_KEY do repositório
```

---

## 10. Webhook por organização

A GitHub App resolve **leitura do código**, não o recebimento dos eventos de deploy.

Para uma organização, mantenha um webhook de organização para `push` apontando para:

```text
https://PUBLIC_IP/github
```

Webhooks de organização podem receber eventos que acontecem nos repositórios da organização.

Configuração desejada por organização:

```text
1 webhook de organização
1 instalação da GitHub App com All repositories
N repositórios
```

Na VPS:

```text
projects.json = allowlist explícita dos projetos/branches que realmente implantam
```

---

## Referências oficiais

- Registering a GitHub App: https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app
- Choosing permissions: https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app
- Installing your own App: https://docs.github.com/en/apps/using-github-apps/installing-your-own-github-app
- Public/private App visibility: https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/making-a-github-app-public-or-private
- Managing private keys: https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps
- Generating a JWT: https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app
- Installation access tokens: https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app
- Repository installation endpoint: https://docs.github.com/en/rest/apps/apps#get-a-repository-installation-for-the-authenticated-app
- Organization webhooks: https://docs.github.com/en/webhooks/types-of-webhooks
