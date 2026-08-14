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
   +--> coloca job na fila
   +--> autentica no GitHub com GitHub App
   +--> busca exatamente o SHA recebido pelo webhook
   +--> executa o adaptador de deploy autorizado
   +--> atualiza containers/arquivos
   +--> atualiza Nginx quando necessário
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

## Contrato de branches

### `homolog`

Um push em:

```text
homolog
```

representa deploy automático do ambiente de homologação.

Padrão desejado para projetos web simples:

```text
https://DOMINIO/hml
```

### `main`

Um push em:

```text
main
```

representa deploy automático de produção.

Padrão desejado:

```text
https://DOMINIO/
```

A mesma versão identificada pelo SHA recebido no webhook deve ser a versão efetivamente implantada. O deploy não deve simplesmente pegar "o último commit disponível" depois que o job começou.

---

## Domínio e configuração do projeto

O domínio e outras informações **não secretas** de deploy devem ser declarativas e versionadas junto ao projeto sempre que possível.

Exemplos de informação não secreta:

```text
domain
deployment type
health-check path
compose files
public path de homolog
public path de production
```

Segredos não pertencem ao repositório.

Exemplos:

```text
senhas
tokens
private keys
webhook secret
chaves de criptografia
credenciais de banco
```

Esses valores permanecem protegidos na VPS.

O formato definitivo do manifesto do projeto será implementado de forma declarativa e restrita. Um repositório não deve poder transformar um campo vindo do webhook em comando shell arbitrário.

---

## Segurança: autorização continua local

A GitHub App pode ter permissão para **ler** muitos repositórios de uma organização. Isso não significa que todos podem executar deploy.

A autorização continua sendo explícita no VPS Deployer:

```text
repository + branch -> ambiente/adaptador autorizado
```

O `/etc/vps-deployer/projects.json` (ou sua evolução compatível) é a allowlist local.

Portanto:

```text
GitHub App access != deploy authorization
```

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

### Helper de autenticação

O helper de GitHub App será infraestrutura interna. Ele não é uma etapa que o operador executa a cada deploy.

O worker chamará automaticamente esse helper para:

1. gerar JWT;
2. localizar a instalação que possui acesso ao repositório;
3. emitir installation access token temporário;
4. autenticar Git via HTTPS sem persistir o token;
5. descartar a credencial temporária após a operação.

### Adaptador de projeto

Cada projeto pode precisar de uma estratégia de deploy diferente, por exemplo:

```text
arquivos estáticos
Docker Compose
Node.js
serviço systemd
monorepo
```

O VPS Deployer seleciona um adaptador previamente autorizado; o payload do webhook nunca fornece um comando shell livre.

---

## TrackPixel e o workflow legado

O workflow existente do TrackPixel em `.github/workflows/deploy.yml` já implementa a ideia de dois ambientes por branch:

```text
main    -> production
homolog -> homolog
```

Porém o roteamento atual do TrackPixel **não usa `/hml`**.

Hoje ele usa:

```text
main:
  https://track.intellifyads.com
  https://pixel.intellifyads.com

homolog:
  https://track-homolog.intellifyads.com
  https://pixel-homolog.intellifyads.com
```

Além disso, o workflow atualmente:

1. faz checkout no runner do GitHub;
2. envia o código para a VPS por SCP;
3. na própria VPS executa `docker compose build`;
4. sobe Postgres e Redis;
5. executa migrations;
6. sobe API, worker e pixel;
7. configura Nginx/TLS;
8. executa health checks.

O novo VPS Deployer deve preservar as partes úteis do deploy e substituir somente o mecanismo de entrega/orquestração:

```text
GitHub Actions checkout + SCP + SSH
              |
              v
webhook + GitHub App + git fetch do SHA na própria VPS
```

O TrackPixel é um exemplo de projeto que possui dois hostnames públicos e pode precisar de um adaptador específico. Antes de migrar esse projeto de subdomínios separados para `/hml`, é necessário validar compatibilidade de API, SDK, URLs públicas e regras de Nginx com path prefix.

O padrão global `/hml` não deve ser aplicado cegamente a um projeto cuja arquitetura exija outro roteamento.

---

## Resultado esperado no uso diário

Para um projeto já configurado:

```bash
git push origin homolog
```

é suficiente para iniciar e concluir o deploy de homologação.

E:

```bash
git push origin main
```

é suficiente para iniciar e concluir o deploy de produção.

Nenhuma outra ação operacional deve ser necessária em condições normais.

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

[NEXT] helper permanente de autenticação GitHub App
[NEXT] fetch/checkout seguro do SHA
[NEXT] adaptador de deploy TrackPixel
[NEXT] cadastrar homolog e main
[NEXT] primeiro deploy real de homolog
[NEXT] validar Nginx/TLS/health checks
[NEXT] deploy de production
[NEXT] desativar workflow GitHub Actions
[NEXT] remover OCI_SSH_KEY legado
```
