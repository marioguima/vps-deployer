# Manifesto de deploy do projeto

O ambiente (`homolog`, `production`) e a forma como ele aparece publicamente são conceitos separados.

A branch responde **qual ambiente será implantado**. O manifesto responde **onde esse ambiente será publicado**.

## Regra de branches

```text
homolog -> ambiente homolog
main    -> ambiente production
```

Isso não significa que homologação sempre usa `/hml` nem que sempre usa subdomínio.

## Modelo técnico único: `host + base_path`

Os três casos que usamos no dia a dia podem ser representados pela mesma estrutura:

```text
produção na raiz:
  host=example.com
  base_path=/

homolog por path:
  host=example.com
  base_path=/hml

homolog por subdomínio:
  host=homolog.example.com
  base_path=/
```

O benefício é não criar três mecanismos diferentes dentro da infraestrutura.

## Local do manifesto

O formato planejado para projetos é um arquivo versionado no próprio repositório:

```text
.vps-deployer.json
```

Ele contém apenas configuração **não secreta**.

Referência de formato neste repositório:

```text
config/project-manifest.example.json
```

## Exemplo: landing pages / páginas de venda

Para um repositório que publica páginas em `firaz.com.br`:

```json
{
  "version": 1,
  "environments": {
    "homolog": {
      "branch": "homolog",
      "public_endpoints": [
        {
          "name": "site",
          "host": "firaz.com.br",
          "base_path": "/hml"
        }
      ]
    },
    "production": {
      "branch": "main",
      "public_endpoints": [
        {
          "name": "site",
          "host": "firaz.com.br",
          "base_path": "/"
        }
      ]
    }
  }
}
```

Resultado:

```text
homolog:
  https://firaz.com.br/hml/nome-da-pagina

production:
  https://firaz.com.br/nome-da-pagina
```

`/hml` é uma rota pública. Não precisa existir como pasta física. O Nginx pode apontá-la para uma raiz de homologação totalmente separada da produção.

## Exemplo: TrackPixel

TrackPixel é uma aplicação/serviço e usa isolamento por hostname.

Conceitualmente o manifesto será:

```json
{
  "version": 1,
  "environments": {
    "homolog": {
      "branch": "homolog",
      "public_endpoints": [
        {
          "name": "track",
          "host": "track-homolog.intellifyads.com",
          "base_path": "/"
        },
        {
          "name": "pixel",
          "host": "pixel-homolog.intellifyads.com",
          "base_path": "/"
        }
      ]
    },
    "production": {
      "branch": "main",
      "public_endpoints": [
        {
          "name": "track",
          "host": "track.intellifyads.com",
          "base_path": "/"
        },
        {
          "name": "pixel",
          "host": "pixel.intellifyads.com",
          "base_path": "/"
        }
      ]
    }
  }
}
```

Portanto, o mesmo modelo atende projetos com um endpoint ou vários endpoints.

## Quando preferir `/hml`

Bom padrão para:

- landing pages;
- páginas de venda;
- páginas estáticas;
- quizzes;
- VSL pages;
- sites simples cujo roteamento suporta prefixo.

Vantagens:

- reaproveita o mesmo domínio e certificado;
- não exige novo DNS por projeto;
- URL de revisão fica previsível;
- homolog e produção continuam fisicamente separados na VPS.

## Quando preferir hostname/subdomínio separado

Bom padrão para:

- APIs;
- aplicações web completas;
- SDKs;
- serviços com cookies próprios;
- aplicações com CORS/callbacks;
- aplicações que não suportam base path com segurança.

Exemplo:

```text
api.example.com
api-homolog.example.com
```

Isso evita reescritas artificiais de `/hml` em aplicações que esperam viver na raiz da origem.

## O manifesto não é autorização

O arquivo versionado descreve a intenção do projeto, mas não transforma qualquer repositório em um deploy autorizado.

A segurança continua em duas camadas:

```text
GitHub App
  -> pode ler o repositório

/etc/vps-deployer/projects.json
  -> autoriza repository + branch + adaptador local
```

Portanto:

```text
manifesto no repo != permissão para executar deploy
```

Um novo repositório precisa ser explicitamente cadastrado na allowlist local antes que pushes possam executar um adaptador.

## Segredos nunca entram no manifesto

Pode entrar:

```text
branch
host
base_path
nome dos endpoints
health-check path
configuração pública de build/deploy
```

Não pode entrar:

```text
password
token
private key
webhook secret
credenciais de banco
chaves de criptografia
```

## Adaptadores e suporte a path prefix

Nem todo adaptador pode publicar em um `base_path` diferente de `/`.

Por exemplo, um adaptador de arquivos estáticos pode mapear `/hml` facilmente. Uma aplicação que gera URLs absolutas pode exigir configuração específica ou hostname separado.

Por isso o VPS Deployer não deve simplesmente adicionar `/hml` na frente de qualquer aplicação. O adaptador precisa declarar/garantir que suporta aquele formato.

## Resultado operacional

Depois do onboarding inicial:

```bash
git push origin homolog
```

publica o ambiente `homolog` de acordo com os endpoints definidos para ele.

E:

```bash
git push origin main
```

publica `production`.

O operador não escolhe `/hml` ou subdomínio durante o push. Isso já está versionado como configuração do projeto.
