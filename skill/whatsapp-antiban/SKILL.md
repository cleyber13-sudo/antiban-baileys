---
name: whatsapp-antiban
description: Sistema antiban do WhatsApp do projeto Contatizs (wa_serever Node/Baileys + painel PHP CodeIgniter) e da biblioteca baileys-antiban. Use SEMPRE que a tarefa envolver ban, bloqueio, 403 forbidden, 401 loggedOut, 463 reachout timelock, risco de ban, HealthMonitor, campanha/bulk pausada sozinha, "Retomar agora", Alertas Antiban, Central Antiban, sp_whatsapp_antiban_alerts, antiban.js, pauseCampaignsForInstance, resumeAntibanPauses, humanização (fingerprint, stealth connect, digitando/presence, typos, read receipts, HumanEntropyService), imagem única (unique_media), piso de delay do bulk, taxa de entrega/resposta, aquecimento de chip ou evolução do antiban — inclusive para diagnosticar uma instância, operar pausas, ajustar config em sp_options, implementar ou revisar código antiban, mesmo que o usuário não diga a palavra "antiban".
---

# Sistema Antiban — Contatizs

Responda em **português do Brasil**; código, comandos e termos técnicos em inglês.

O antiban reduz (não elimina) o risco de o WhatsApp bloquear números conectados via
Baileys (API não-oficial). Ele vive quase todo no Node (`wa_serever/`), que é dono dos
sockets; o PHP só configura, mostra e aciona.

## Mapa rápido (caminhos relativos a `<RAIZ_PROJETO>`)

| Peça | Arquivo |
|---|---|
| Fachada sobre a lib, todo estado por instância | `wa_serever/waziper/antiban.js` |
| Integração (socket, eventos, envio, pausa, retomada, crons) | `wa_serever/waziper/waziper.js` |
| Endpoints `/health_status`, `/antiban_resume`, `/antiban_overview` | `wa_serever/app.js` |
| Fila do bulk + ack/leitura/resposta | `wa_serever/waziper/bulk_queue.js` |
| Imagem com hash único | `wa_serever/waziper/media_variant.js` |
| Resolvedor @lid com disjuntor | `wa_serever/waziper/lid_resolver.js` |
| Fallback de config | `wa_serever/config.js` → `antiban_humanize`, `lid_resolver` |
| Central Antiban (admin) | `inc/core/Whatsapp_antiban/` |
| Alertas Antiban e ações de pausa | `inc/core/Whatsapp_profiles/Controllers/Whatsapp_profiles.php` (+ `Views/antiban_alerts.php`) |
| Piso de delay / engajamento | `app/Helpers/Common_helper.php` (`bulk_delay_floor`, `validate_bulk_delay`, `bulk_engagement`) |
| Migrations | `inc/core/Whatsapp/Database/Migrations/antiban_*.sql`, `inc/core/Whatsapp_bulk/Database/Migrations/*.sql` |
| Lib | `wa_serever/node_modules/baileys-antiban` (v4.10.0) |

Os números de linha mudam: localize por nome de função (`grep -n "pauseCampaignsForInstance\|resumeAntibanPauses\|Antiban\." wa_serever/waziper/waziper.js`).

## Como o sistema funciona (resumo)

1. **Detecção** — `HealthMonitor` (lib) por instância pontua 403 (+40), 401 (+60), 463
   (+25), quedas ≥ 3/h (+30), falhas ≥ 5/h (+20); decai 5 pts/min (2 após 401/403).
   Faixas reais: medium ≥ 15, **high ≥ 40 (pausa)**, critical ≥ 80. Quedas de infra
   (428, 408, 515, 503, 1000, 1001, 1005, 1006, unknown) **não pontuam**. Score no Redis
   `antiban:health:<id>` (6 h).
2. **Pausa real** — 463 (stub em `messages.update`), 401 e 403 (`connection.update`
   close) chamam `pauseCampaignsForInstance`: campanhas `status=1` da instância →
   `status=0` gravando `changed`; alerta em `sp_whatsapp_antiban_alerts` (funde se já
   houver pendente); webhook; socket.io. Cooldown: 463 = 3600 s × 2^(n−1) (só manual
   após 3); 401/403 = 600 s, re-bloqueio ≤ 180 s após retomar → só manual.
3. **Bloqueio** — `isTimelockBlocked` (síncrono) e `isHealthPaused` nos gates do
   `bulk_messaging` e do `auto_send`; saem com `stats:false` (contato não é queimado).
   `live_back` não recria socket por 10 min após 401/403.
4. **Retomada** — cron 30 s `resumeAntibanPauses`: fecha órfãos (campanha mexida por
   fora, `changed` diferente); **retomada automática desligada por padrão**
   (`antiban_auto_resume=0`); "Retomar agora" grava `forced_resume=1` (ignora risco,
   reseta o score, exige socket vivo, respeita `changed`).
5. **Humanização** — fingerprint determinístico por instância; stealth connect
   (online só após 30–120 s); digitação WPM circadiana escalada para `presenceTime`;
   typos (2 %), read receipts com atraso e ruído de fundo (entropy 2–6 h) por
   allowlist/override, configurados na Central Antiban sem restart (TTL 60 s).
6. **Cadência do bulk** — piso 8 s + gap 4 s; settle 120 s pós-conexão; falha
   transitória → backoff 30–60 s sem queimar contato; `unique_media`.

## Fluxos de trabalho

### A. Diagnosticar uma instância / "a campanha parou"

1. Rode o diagnóstico somente-leitura (está nesta skill):
   ```bash
   bash <dir-da-skill>/scripts/diagnostico.sh <instance_id>   # ou sem argumento: frota
   ```
   Mostra `sp_options` antiban, pausas pendentes, eventos 7 dias, entrega/leitura/
   resposta, conta, campanhas, Redis e as linhas `[ANTIBAN]/[bulk]/[live_back]/[status]`
   dos logs do pm2 (`<PM2_LOG_DIR>/contatizs-{error,out}*.log`).
2. Interprete com `references/03-pausa-e-retomada.md` e `references/10-runbook-operacional.md`.
3. Explique ao usuário: tipo do evento, o que o sistema fez, o que falta para voltar
   e a recomendação (esperar cooldown, re-parear, reduzir volume, trocar chip na 3ª vez).
4. **Não** retome campanhas, não edite `sp_options` nem reinicie o pm2 sem o usuário
   pedir — são ações com efeito em produção (restart derruba todas as conexões).

### B. Ajustar configuração

Toda config está em `sp_options` (tabela completa em `references/07-banco-config-redis.md`).
Prefira orientar pela Central Antiban (admin → Antiban). Valores ≤ 0 caem no default.
Humanização vale em ~1 min; timelock/cooldown em ~5 min; fingerprint e stealth na
próxima reconexão. Mudança de **código** no Node exige `pm2 restart <PM2_APP>`.

### C. Implementar ou alterar algo no antiban

Leia antes `references/02-modulo-antiban-js.md` e o trecho real do código. Respeite as
invariantes:

- **Fail-open:** nada do antiban pode lançar para o fluxo de envio/recebimento —
  `try/catch` silencioso, fire-and-forget onde couber; Redis fora do ar não bloqueia.
- **Não queimar contato:** bloqueio do antiban ou falha transitória → `stats:false`.
- **Fonte de verdade = banco:** pausa grava `changed`; retomada só religa se `status=0`
  e `changed` igual. Memória/Redis são cache; reidratar no boot quando necessário.
- **Toda nova config:** chave `antiban_*` em `sp_options` + default no código + leitura
  com TTL + (se exposta) `GLOBAL_KEYS` em `Whatsapp_antiban` + view + traduções em
  `writable/lang/pt-br.json` e `es-mx.json`.
- **Opt-in por instância** para comportamento invasivo (override > allowlist).
- `waziper.js` nunca usa a lib direto: exponha via `antiban.js` e registre handlers
  (`set*Handler`) para evitar require circular.
- PHP: constantes `TB_*`, filtro por `team_id`, POST manual com token `csrf`, migração
  SQL não-destrutiva e sem `COLLATE` explícito em `instance_id`.
- Testes do Node ficam em `wa_serever/waziper/tests/*.test.js`; valide sintaxe com
  `node -e "require('./waziper/antiban.js')"` dentro de `wa_serever/`.
- Ao terminar, diga explicitamente que o código Node só vale após restart do pm2.

Antes de adotar um módulo novo da lib, consulte `references/08-biblioteca-baileys-antiban.md`
e `references/09-lib-vs-projeto.md` (divergências: faixas do README erradas,
`classifyDisconnect` trata 428/515 como fatal, HealthMonitor conta queda de infra,
HumanEntropyService acoplado ao WaSP, `growthFactor` aleatório).

### D. Revisar código que toca o antiban

Cheque as invariantes de C e, em especial: caminho que chama `recordMessageFailed` para
erro transitório (contamina o score); gate novo que devolve `stats:true` (queima
contato); retomada que não confere `changed`; `await` faltando antes de apagar sessão
no 401/403; novo código de close que deveria estar em `INFRA_DISCONNECT_CODES`.

### E. Planejar evolução

Use `references/11-historico-roadmap.md` (prioridades: taxa de entrega → score e
circuit breaker por campanha; warmup/teto por idade; intervalo gaussiano + micro-pausas;
retomada rampada; orçamento por IP). Seja honesto: Baileys só adia 463/401/403; para
volume alto, Cloud API oficial.

## Referências (carregue sob demanda)

| Arquivo | Quando ler |
|---|---|
| `references/01-visao-geral-arquitetura.md` | visão de componentes e fluxos |
| `references/02-modulo-antiban-js.md` | API de `antiban.js`, estado, Redis, HCFG |
| `references/03-pausa-e-retomada.md` | pausa/retomada, máquina de estados, botões |
| `references/04-humanizacao.md` | fingerprint, stealth, presença, typos, leitura, entropy, unique_media |
| `references/05-cadencia-bulk.md` | gates, piso, settle, transitória, rastreio |
| `references/06-painel-php.md` | Central Antiban, Alertas, rotas, endpoints |
| `references/07-banco-config-redis.md` | tabelas, todas as chaves, Redis, webhooks |
| `references/08-biblioteca-baileys-antiban.md` | referência PT-BR da lib v4.10.0 |
| `references/09-lib-vs-projeto.md` | o que é usado, divergências, lacunas |
| `references/10-runbook-operacional.md` | logs, SQL, procedimentos, checklist |
| `references/11-historico-roadmap.md` | linha do tempo e roadmap |
| `references/12-codigos-glossario.md` | códigos de desconexão/erro, ack, glossário |
