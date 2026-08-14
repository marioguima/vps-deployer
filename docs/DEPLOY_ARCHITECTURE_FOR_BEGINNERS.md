# Arquitetura de deploy explicada para leigos

Este documento explica por que o VPS Deployer usa três elementos diferentes — **webhook**, **GitHub App** e **SHA do commit** — e por que nenhum deles substitui os outros.

## A ideia em uma frase

Pense no deploy como uma entrega:

- **Webhook** = a campainha: avisa que existe algo novo para entregar;
- **GitHub App** = o crachá/chave: prova que a VPS pode entrar no repositório privado e ler o código;
- **SHA** = o número exato da encomenda: identifica qual versão do código deve ser implantada.

Os três trabalham juntos.

---

## 1. Webhook: o aviso

Quando acontece um `push`, o GitHub envia uma requisição HTTP para:

```text
https://PUBLIC_IP/github
```

O webhook informa, entre outras coisas:

```text
repository
branch
commit SHA
sender
```

Exemplo conceitual:

```text
marioguima/trackpixel
branch: homolog
SHA: abc123...
```

O webhook **não envia o código-fonte inteiro**. Ele apenas avisa o VPS Deployer de que um commit específico existe e deve ser considerado para deploy.

O VPS Deployer valida a assinatura HMAC do webhook, verifica a allowlist `repository + branch`, persiste o job no SQLite e responde rapidamente ao GitHub.

### O que o webhook resolve

```text
GitHub -> VPS
"houve um push; este é o repositório, a branch e o SHA"
```

### O que ele não resolve

O webhook não dá à VPS permissão para ler um repositório privado.

---

## 2. GitHub App: a identidade de leitura

Depois que o webhook diz qual commit deve ser implantado, a VPS precisa obter os arquivos daquele commit.

Para repositório público isso poderia ser feito sem autenticação. Para repositório privado, o GitHub exige uma identidade autorizada.

A GitHub App é essa identidade:

```text
VPS -> GitHub
"sou o VPS Deployer; tenho permissão para ler este repositório"
```

A App deste projeto deve ter o mínimo necessário:

```text
Repository permissions
Contents: Read-only
Metadata: Read-only (concedido/necessário pelo GitHub)
```

Não precisa de permissão de escrita, Issues, Pull Requests, Actions ou Administration para apenas clonar/fazer fetch do código.

A VPS não precisa guardar senha pessoal do GitHub. Ela guarda a identidade da App e usa **installation access tokens temporários** para autenticar operações Git via HTTPS.

Esses tokens expiram e são renovados programaticamente quando necessário.

### Por que usar uma App em vez de Deploy Key

Deploy Key funciona bem para um único repositório, mas normalmente exige configuração por repositório.

A GitHub App pode ser instalada em uma conta pessoal e em várias organizações. Quando instalada com acesso a `All repositories`, novos repositórios da organização passam a estar disponíveis para a App sem precisar criar uma nova chave para cada projeto.

Isso reduz drasticamente a configuração repetitiva.

---

## 3. SHA: a versão exata

Uma branch como `homolog` é um ponteiro móvel.

Imagine:

```text
10:00 webhook chega dizendo que homolog estava em SHA A
10:01 outro push move homolog para SHA B
10:02 o worker começa o deploy
```

Se o script simplesmente fizer:

```bash
git checkout homolog
git pull
```

pode acabar implantando o SHA B, embora o job tenha sido criado para o SHA A.

Por isso o VPS Deployer usa o SHA recebido pelo webhook:

```bash
git fetch
git checkout "$DEPLOY_SHA"
```

Assim, o job implanta **exatamente o commit que disparou aquele webhook**.

### O que o SHA resolve

```text
"não quero apenas a branch homolog;
quero exatamente o commit abc123... que originou este job"
```

O SHA não concede acesso ao repositório. Ele apenas identifica a versão.

---

## Como os três se encaixam

```text
1. Desenvolvedor faz push
        |
        v
2. GitHub envia webhook
        |
        | repository + branch + SHA
        v
3. VPS Deployer valida assinatura e allowlist
        |
        v
4. Job entra no SQLite
        |
        v
5. Worker inicia
        |
        v
6. VPS autentica no GitHub usando GitHub App
        |
        v
7. git fetch do repositório privado
        |
        v
8. checkout exato de DEPLOY_SHA
        |
        v
9. script do projeto executa build/migrate/up
```

---

## Um quarto elemento importante: projects.json

Mesmo que um webhook chegue corretamente e a GitHub App tenha acesso ao código, isso **não significa que qualquer repositório pode executar deploy na VPS**.

A autorização final continua local:

```text
/etc/vps-deployer/projects.json
```

Exemplo:

```json
{
  "repository": "minha-org/projeto",
  "branch": "homolog",
  "command": ["/opt/vps-deployer/project-scripts/projeto.sh", "homolog"]
}
```

Portanto:

```text
Webhook de organização = recebe eventos de toda a organização
GitHub App = pode ler os repositórios autorizados na instalação
projects.json = decide quais repo + branch realmente podem executar deploy
```

Esse último filtro é propositalmente explícito por segurança.

---

## Organização: configuração mínima para novos projetos

O objetivo final é:

```text
Organização GitHub
├── 1 webhook de organização -> VPS
├── 1 instalação da GitHub App -> All repositories
├── projeto-a
├── projeto-b
└── projetos futuros
```

Para um novo repositório dentro de uma organização já preparada, não deve ser necessário criar:

```text
nova SSH key
novo OCI_SSH_KEY
novo PAT
novo webhook por repositório
nova GitHub App
```

O único passo propositalmente por deploy continua sendo cadastrá-lo na allowlist local e definir seu script/padrão de execução.

---

## Referências oficiais

- GitHub App permissions e Git over HTTPS: https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app
- Installation access tokens: https://docs.github.com/en/rest/apps/apps#create-an-installation-access-token-for-an-app
- Organization webhooks: https://docs.github.com/en/webhooks/types-of-webhooks
- Installing your own GitHub App: https://docs.github.com/en/apps/using-github-apps/installing-your-own-github-app
