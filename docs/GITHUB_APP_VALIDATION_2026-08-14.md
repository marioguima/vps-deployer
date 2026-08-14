# Validação real da GitHub App — 2026-08-14

Este registro complementa `docs/GITHUB_APP_SETUP.md` com os problemas encontrados durante a primeira validação real na VPS.

## Estado validado

GitHub App:

```text
marioguima-vps-deployer
App ID: 4592846
```

A private key foi instalada em:

```text
/etc/vps-deployer/github-app.pem
```

com:

```text
owner: root
group: vps-deployer
mode: 0640
```

O usuário `vps-deployer` conseguiu ler a chave.

A identidade da App foi validada com JWT assinado pela private key e Client ID:

```text
GET /app -> HTTP 200
name=marioguima-vps-deployer
slug=marioguima-vps-deployer
id=4592846
```

A instalação para `marioguima/trackpixel` também foi encontrada e um installation access token temporário foi emitido com sucesso:

```text
installation_id=153676006
token emitido com sucesso
```

Nunca registrar JWT, installation token ou conteúdo da private key neste repositório.

## Erro 1 — `Integration not found`

Durante o primeiro teste foi configurado por engano:

```text
GITHUB_APP_ID=4592046
```

O App ID correto é:

```text
GITHUB_APP_ID=4592846
```

O valor incorreto resultou em:

```text
HTTP 404
message=Integration not found
```

Um teste usando o Client ID como `iss` do JWT retornou `GET /app -> HTTP 200` e revelou o App ID correto. O helper definitivo deve preferir `GITHUB_APP_CLIENT_ID` para o claim `iss`.

## Erro 2 — `fatal: failed to stat '/home/ubuntu/vps-deployer': Permission denied`

Depois que a autenticação da App e a emissão do token já haviam funcionado, o comando `git ls-remote` falhou com:

```text
fatal: failed to stat '/home/ubuntu/vps-deployer': Permission denied
```

### Causa

O teste foi iniciado pelo usuário `ubuntu` estando em:

```text
/home/ubuntu/vps-deployer
```

com:

```bash
sudo -u vps-deployer bash ...
```

`sudo -u` troca o usuário, mas preserva o diretório atual. O usuário de sistema `vps-deployer` não precisa e não deve ganhar acesso ao home privado de `ubuntu`; por isso o Git falhou ao tentar consultar o diretório corrente antes de executar a operação remota.

Esse erro **não indica falha da GitHub App**. A instalação já havia sido localizada e o installation access token já havia sido emitido.

### Solução

Para testes manuais executados como `vps-deployer`, primeiro entrar em um diretório acessível ao usuário de serviço:

```bash
cd /tmp
sudo -u vps-deployer bash <<'EOF'
# teste
EOF
```

No código definitivo, scripts do deployer devem definir explicitamente seu working directory e nunca depender do diretório atual herdado do usuário `ubuntu`.

### Não fazer

Não corrigir esse problema abrindo permissões de `/home/ubuntu`. O isolamento entre `ubuntu` e `vps-deployer` é desejável.
