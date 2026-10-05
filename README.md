# Sistema Antiban — Contatizs (WhatsApp via Baileys)

Documentação técnica completa, em português, do **sistema antiban** do painel
Contatizs e da biblioteca em que ele se
apoia, a [`baileys-antiban`](https://github.com/kobie3717/baileys-antiban) (v4.10.0).

> Documentação do código em **2026-10-05**. Os caminhos citados (`wa_serever/...`,
> `inc/core/...`) são relativos à raiz do projeto. Caminhos de servidor, porta e
> nome do processo aparecem como marcadores (`<RAIZ_PROJETO>`, `<PM2_APP>`,
> `<PM2_LOG_DIR>`, `<PORTA_WA>`) e IDs de instância como `INSTANCIA_A`…`D`.

## O que é o "antiban"

O WhatsApp derruba números que se comportam como robô. O sistema antiban é o
conjunto de camadas que **reduz** (não elimina) esse risco nos números
conectados via Baileys (API não-oficial):

| Camada | O que faz | Onde |
|---|---|---|
| **Detecção de risco** | `HealthMonitor` pontua quedas, 403, 401, 463 e falhas de envio; persiste no Redis | `wa_serever/waziper/antiban.js` |
| **Pausa real** | 463 / 401 / 403 pausam as campanhas da instância e abrem um alerta com cooldown | `waziper.js` → `pauseCampaignsForInstance()` |
| **Retomada** | Manual ("Retomar agora") por padrão; automática opcional (`antiban_auto_resume`) | `waziper.js` → `resumeAntibanPauses()` |
| **Humanização** | Fingerprint por instância, stealth connect, digitação WPM, erros de digitação, leitura com atraso, ruído de fundo | `antiban.js` + Central Antiban |
| **Cadência do bulk** | Piso de intervalo, estabilização pós-conexão, falha transitória não queima contato, imagem única | `waziper.js` + `Common_helper.php` |
| **Observabilidade** | Alertas no painel, webhooks `antiban.*`, métricas de entrega/leitura/resposta | `Whatsapp_profiles`, `Whatsapp_antiban`, `bulk_queue.js` |

## Índice

| # | Documento | Conteúdo |
|---|---|---|
| 01 | [Visão geral e arquitetura](docs/01-visao-geral-arquitetura.md) | Componentes, fluxos, diagrama, princípios de projeto |
| 02 | [Módulo `antiban.js` (API)](docs/02-modulo-antiban-js.md) | Todas as funções exportadas, estado em memória, Redis |
| 03 | [Pausa real e retomada](docs/03-pausa-e-retomada.md) | 463 / 401 / 403, cooldown, reincidência, fusão, forced resume, máquina de estados |
| 04 | [Humanização](docs/04-humanizacao.md) | Fingerprint, stealth connect, presença WPM, typos, read receipts, entropy, imagem única |
| 05 | [Cadência e fila do bulk](docs/05-cadencia-bulk.md) | Gates de envio, piso de delay, settle, falha transitória, rastreio de entrega |
| 06 | [Painel PHP](docs/06-painel-php.md) | Central Antiban (admin), Alertas Antiban, endpoints e rotas |
| 07 | [Banco, configuração e Redis](docs/07-banco-config-redis.md) | Tabelas, todas as chaves `sp_options`, `config.js`, chaves Redis, webhooks |
| 08 | [Biblioteca `baileys-antiban`](docs/08-biblioteca-baileys-antiban.md) | Referência em PT-BR de todos os módulos da lib v4.10.0 |
| 09 | [Lib × projeto: o que usamos](docs/09-lib-vs-projeto.md) | Matriz de adoção, divergências, lacunas |
| 10 | [Runbook operacional](docs/10-runbook-operacional.md) | Diagnóstico, logs, SQL úteis, restart, procedimentos |
| 11 | [Histórico e roadmap](docs/11-historico-roadmap.md) | Linha do tempo das mudanças e o que falta implementar |
| 12 | [Códigos e glossário](docs/12-codigos-glossario.md) | Códigos de desconexão/erro do WhatsApp e termos |

## Estrutura do repositório

```
.
├── README.md                      ← este arquivo
├── docs/                          ← documentação técnica (PT-BR)
├── biblioteca/baileys-antiban/    ← README, CHANGELOG, LICENSE (MIT) e docs originais da lib
├── skill/whatsapp-antiban/        ← skill do Claude Code (SKILL.md, references/, scripts/diagnostico.sh)
├── scripts/sync-skill.sh          ← copia docs/ → skill/references e instala a skill
└── .local.env.example             ← modelo dos valores reais de infra (o .local.env não vai pro git)
```

## Skill do Claude Code

A pasta [`skill/whatsapp-antiban/`](skill/whatsapp-antiban/) contém uma skill
completa (`SKILL.md` + referências) para o Claude Code diagnosticar, operar e
evoluir o antiban. Para instalar:

```bash
scripts/sync-skill.sh --projeto   # <RAIZ_PROJETO>/.claude/skills/ (já instalada)
scripts/sync-skill.sh --global    # ~/.claude/skills/ (todos os projetos)
```

Antes de instalar, copie `.local.env.example` para `.local.env` e preencha os
valores reais: o script os aplica **só na cópia instalada**, o repositório continua
com marcadores.

As `references/` da skill são cópias de `docs/`: depois de editar um doc, rode
`scripts/sync-skill.sh` (com `--projeto` para atualizar a cópia instalada).

O script `skill/whatsapp-antiban/scripts/diagnostico.sh [instance_id]` faz um
diagnóstico **somente leitura** (sp_options, pausas, eventos, entrega/resposta,
Redis e logs do pm2), lendo as credenciais do `.env` do projeto.

## Aviso honesto

Baileys é API **não-oficial**. Todas as camadas aqui **adiam** bloqueios
(463, 401, 403); nenhuma os elimina. Para volume alto de verdade, o único
caminho sem jogo de gato e rato é a **WhatsApp Cloud API** (oficial).

## Licenças

- Código e docs do projeto Contatizs: uso interno.
- `biblioteca/baileys-antiban/`: cópia dos documentos da lib, licença MIT
  (© Kobus Wentzel) — ver [`biblioteca/baileys-antiban/LICENSE`](biblioteca/baileys-antiban/LICENSE).
