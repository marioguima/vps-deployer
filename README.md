# VPS Deployer

Um deployer global, pequeno e independente de GitHub Actions para uma VPS.

Ele recebe eventos `push` do GitHub, valida a assinatura do webhook, identifica `owner/repo + branch`, coloca o deploy em uma fila persistente e executa **um deploy por vez** usando scripts previamente cadastrados na VPS.

Foi desenhado para atender repositórios pessoais e de múltiplas organizações com **um único serviço**.

```text
GitHub repo/org webhooks
          │
          │ push
          ▼
https://PUBLIC_IP/github
          │
          ▼
    vps-deployer
     1 processo
          │
          ▼
      SQLite queue
          │
          ▼
  1 deploy por vez
          │
    ┌─────┼─────┐
    ▼     ▼     ▼
 repo A  repo B repo C
```

## Por que existe

GitHub-hosted Actions consomem a franquia de minutos. Self-hosted runners resolvem o custo, mas runners sem GitHub Enterprise ficam limitados ao escopo de um repositório ou de uma organização. Quando a mesma VPS recebe projetos de uma conta pessoal e de várias organizações, isso força múltiplos runners.

O VPS Deployer evita esse acoplamento:

- não usa GitHub Actions;
- não usa polling;
- não exige GitHub Enterprise;
- não exige um domínio;
- não exige Redis, banco externo ou container;
- aceita webhooks de qualquer repositório/organização configurado;
- mantém apenas um processo residente;
- serializa os builds para não sobrecarregar a VPS.

## Requisitos

Base:

- Linux com `systemd`;
- Python 3.10+;
- Git para os scripts de deploy que clonam repositórios.

Para o modo HTTPS recomendado por IP:

- IP público fixo;
- Nginx;
- Certbot **5.4+**;
- portas 80 e 443 liberadas na VPS e no firewall/security-list do provedor.

O próprio deployer não depende de Docker. Docker é necessário somente para projetos cujos scripts de deploy o utilizem.

---

# Instalação em uma VPS nova

Esta é a seção principal para usar quando você trocar de servidor e não lembrar de nada da implementação.

## 1. Clone este repositório

```bash
git clone https://github.com/marioguima/vps-deployer.git
cd vps-deployer
```

## 2. Instale o serviço

```bash
sudo ./scripts/install.sh
```

O instalador cria:

```text
/opt/vps-deployer/app/                 código em execução
/opt/vps-deployer/project-scripts/     scripts de cada projeto
/etc/vps-deployer/env                  segredo/configuração do receiver
/etc/vps-deployer/projects.json        registry repo + branch -> script
/var/lib/vps-deployer/jobs.sqlite3     fila e histórico
/var/log/vps-deployer/                 logs dos deploys
/etc/systemd/system/vps-deployer.service
```

Ele cria o usuário de sistema `vps-deployer`. Se o grupo `docker` já existir, o usuário é adicionado a ele para que scripts possam chamar Docker sem executar o servidor HTTP como root.

> Acesso ao grupo `docker` é efetivamente privilegiado. Leia [docs/SECURITY.md](docs/SECURITY.md).

## 3. Configure o segredo do webhook

Gere um segredo forte:

```bash
openssl rand -hex 32
```

Edite:

```bash
sudo nano /etc/vps-deployer/env
```

Troque:

```env
VPS_DEPLOYER_WEBHOOK_SECRET=CHANGE_ME_WITH_A_LONG_RANDOM_SECRET
```

pelo valor gerado.

No modo HTTPS recomendado, mantenha:

```env
VPS_DEPLOYER_BIND=127.0.0.1
VPS_DEPLOYER_PORT=9100
```

O mesmo segredo deverá ser informado nos webhooks do GitHub.

## 4. Cadastre os projetos

Edite:

```bash
sudo nano /etc/vps-deployer/projects.json
```

Exemplo:

```json
{
  "deployments": [
    {
      "repository": "marioguima/trackpixel",
      "branch": "homolog",
      "command": ["/opt/vps-deployer/project-scripts/trackpixel.sh", "homolog"],
      "timeout_seconds": 1800,
      "enabled": true
    },
    {
      "repository": "marioguima/trackpixel",
      "branch": "main",
      "command": ["/opt/vps-deployer/project-scripts/trackpixel.sh", "production"],
      "timeout_seconds": 1800,
      "enabled": true
    },
    {
      "repository": "Trabalhos-Manuais/outro-projeto",
      "branch": "main",
      "command": ["/opt/vps-deployer/project-scripts/outro-projeto.sh", "production"],
      "timeout_seconds": 1200,
      "enabled": true
    }
  ]
}
```

O arquivo é relido quando cada webhook chega. **Adicionar um projeto não exige restart do serviço.**

O conteúdo recebido do GitHub nunca vira um comando shell. O webhook apenas seleciona uma entrada exata de `repository + branch`; o comando executável vem deste arquivo local.

## 5. Crie o script de deploy do projeto

Cada projeto decide como é implantado. O deployer fornece estas variáveis:

```text
DEPLOY_JOB_ID
DEPLOY_DELIVERY_ID
DEPLOY_REPOSITORY
DEPLOY_REF
DEPLOY_BRANCH
DEPLOY_SHA
DEPLOY_SENDER
```

Há um exemplo em:

```text
examples/deploy-git-docker-compose.sh
```

Copie e adapte:

```bash
sudo cp examples/deploy-git-docker-compose.sh \
  /opt/vps-deployer/project-scripts/trackpixel.sh
sudo chmod 755 /opt/vps-deployer/project-scripts/trackpixel.sh
```

Os scripts devem fazer checkout de **`DEPLOY_SHA`**, não simplesmente da ponta atual da branch. Isso garante que o deploy corresponde ao push recebido.

## 6. Configure acesso Git aos repositórios privados

O deployer não precisa de token da API do GitHub. Os scripts podem usar Git via SSH.

Configure uma chave adequada para o usuário `vps-deployer` e valide:

```bash
sudo -u vps-deployer ssh -T git@github.com
```

Escolha a menor permissão que atenda seus repositórios. Não coloque chaves privadas neste repositório.

## 7. Valide e inicie

```bash
sudo vps-deployer-doctor
sudo systemctl enable --now vps-deployer
sudo systemctl status vps-deployer
```

Teste localmente:

```bash
curl http://127.0.0.1:9100/health
```

Resposta esperada:

```json
{"ok":true,"service":"vps-deployer","time":"..."}
```

---

# HTTPS usando somente o IP público

Um domínio não é necessário.

Let's Encrypt atualmente emite certificados para endereços IP. Esses certificados são curtos, portanto a renovação automática do Certbot é parte obrigatória da instalação.

O script abaixo exige Certbot 5.4+:

```bash
sudo ./scripts/setup-ip-tls.sh PUBLIC_IP SEU_EMAIL
```

Exemplo:

```bash
sudo ./scripts/setup-ip-tls.sh 203.0.113.10 email@example.com
```

O script:

1. valida Nginx e a versão do Certbot;
2. publica o challenge HTTP em `:80`;
3. solicita certificado para o IP;
4. configura Nginx em `:443`;
5. mantém o Python somente em `127.0.0.1:9100`;
6. instala hook de reload do Nginx após renovações.

Depois:

```text
Webhook: https://PUBLIC_IP/github
Health:  https://PUBLIC_IP/health
```

Confira também se o timer de renovação do Certbot está ativo:

```bash
systemctl list-timers | grep -i certbot
```

Se o Certbot fornecido pela distribuição for antigo, instale uma versão 5.4+ pelos canais oficiais do Certbot antes de executar o script.

---

# Configurando o GitHub

## Repositório individual

No repositório:

```text
Settings
→ Webhooks
→ Add webhook
```

Configure:

```text
Payload URL:  https://PUBLIC_IP/github
Content type: application/json
Secret:       mesmo VPS_DEPLOYER_WEBHOOK_SECRET
Events:       Just the push event
Active:       marcado
```

O GitHub envia um `ping` ao criar o webhook. O receiver responde `200` ao `ping`.

## Organização

Para uma organização em que você administra webhooks, configure **um webhook da organização** apontando para o mesmo endpoint e selecione o evento `push`.

Assim vários repositórios da organização chegam ao mesmo processo. Somente pares `repository + branch` existentes em `projects.json` geram deploy; os demais recebem `202` e são ignorados.

Para repositórios pessoais, cadastre o webhook nos repositórios que devem fazer deploy nessa VPS.

---

# Funcionamento do webhook

Para cada requisição:

1. aceita somente `POST /github`;
2. limita o tamanho do payload;
3. valida `X-Hub-Signature-256` sobre o **body original** usando HMAC-SHA256;
4. usa `X-GitHub-Delivery` como chave idempotente;
5. aceita `ping` e `push`; outros eventos são ignorados;
6. lê `repository.full_name`, `ref` e `after` (SHA);
7. procura uma correspondência exata em `projects.json`;
8. persiste o job no SQLite;
9. responde `202` sem esperar o deploy terminar;
10. o worker único executa os jobs em ordem.

Se o serviço cair durante um deploy, jobs que estavam como `running` retornam para `queued` ao iniciar novamente.

---

# Operação diária

## Ver serviço

```bash
sudo systemctl status vps-deployer
```

## Acompanhar receiver/worker

```bash
sudo journalctl -u vps-deployer -f
```

## Listar deploys

```bash
sudo vps-deployer-jobs
```

Exemplo:

```text
ID  STATUS     REPOSITORY             BRANCH   SHA          RECEIVED
17  succeeded  marioguima/projeto-a   main     abc123...    ...
16  failed     Org/projeto-b           homolog  def456...    ...
```

## Log de um job

```bash
sudo less /var/log/vps-deployer/job-17.log
```

## Reexecutar um deploy que falhou

```bash
sudo vps-deployer-retry 16
```

O worker detectará o job novamente em poucos segundos.

---

# Atualizando o próprio VPS Deployer

Na cópia clonada deste repositório:

```bash
git pull
sudo ./scripts/install.sh
sudo vps-deployer-doctor
sudo systemctl restart vps-deployer
```

O instalador é idempotente e preserva:

- `/etc/vps-deployer/env`;
- `/etc/vps-deployer/projects.json`;
- banco SQLite;
- logs;
- scripts específicos dos projetos.

---

# Backup e migração para outra VPS

O código não precisa ser copiado: clone este repositório novamente.

Faça backup apenas do estado/configuração local:

```text
/etc/vps-deployer/
/opt/vps-deployer/project-scripts/
```

Opcionalmente, para preservar histórico:

```text
/var/lib/vps-deployer/jobs.sqlite3
/var/log/vps-deployer/
```

Em uma VPS nova:

```text
1. clone este repo
2. sudo ./scripts/install.sh
3. restaure /etc/vps-deployer
4. restaure /opt/vps-deployer/project-scripts
5. configure Git/SSH
6. sudo vps-deployer-doctor
7. sudo systemctl enable --now vps-deployer
8. configure HTTPS para o NOVO IP
9. altere os Payload URLs dos webhooks para o NOVO IP
```

Essa é toda a dependência necessária para reconstruir o serviço.

---

# Modo HTTP direto — somente bootstrap/emergência

Se você precisar testar antes de configurar Nginx/TLS, altere temporariamente:

```env
VPS_DEPLOYER_BIND=0.0.0.0
VPS_DEPLOYER_PORT=9100
```

Reinicie:

```bash
sudo systemctl restart vps-deployer
```

Libere a porta 9100 no firewall e use:

```text
http://PUBLIC_IP:9100/github
```

A assinatura HMAC continua obrigatória, mas este modo **não oferece confidencialidade de transporte**. Prefira o HTTPS por IP e volte o bind para `127.0.0.1` assim que possível.

---

# Testes de desenvolvimento

Não há dependências externas:

```bash
python3 -m unittest discover -s tests -v
```

Validação de shell básica:

```bash
bash -n scripts/*.sh examples/*.sh
```

## Princípios do projeto

- global, não ligado a produto/empresa;
- um processo por VPS;
- evento, não polling;
- fila persistente;
- deploy serial por padrão;
- configuração explícita por repositório e branch;
- payload nunca controla um comando arbitrário;
- sem GitHub Actions e sem minutos de runner hospedado;
- instalação reproduzível e documentação suficiente para reconstrução meses depois.

Veja também [docs/SECURITY.md](docs/SECURITY.md).
