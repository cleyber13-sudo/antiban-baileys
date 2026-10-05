# 01 — Visão geral e arquitetura

## 1. Contexto

O Contatizs tem dois runtimes que compartilham o mesmo MySQL:

1. **Painel PHP** (CodeIgniter 4, módulos em `inc/core/<Modulo>`) — UI, campanhas, configuração.
2. **`wa_serever/`** (Node.js/Express, porta `<PORTA_WA>`) — dono das conexões WhatsApp via
   Baileys (fork `@itsukichan/baileys`). O PHP fala com ele por HTTP (`wa_get_curl()`).

O antiban vive majoritariamente no **Node** (é lá que estão os sockets e os
eventos do WhatsApp). O PHP só configura, mostra e aciona.

## 2. Componentes

```
┌──────────────────────────── PAINEL PHP (CodeIgniter) ────────────────────────────┐
│ inc/core/Whatsapp_antiban      Central Antiban (admin, role=1)                   │
│   index/save/override/overview  → grava sp_options (antiban_*) e overrides JSON  │
│ inc/core/Whatsapp_profiles     Alertas Antiban (por time)                        │
│   antiban_alerts / antiban_status / timelock_hold / timelock_release /           │
│   antiban_dismiss / clear_alerts / mark_alert_read                               │
│ inc/core/Whatsapp_bulk         validate_bulk_delay(), unique_media, presence     │
│ app/Helpers/Common_helper.php  bulk_delay_floor(), validate_bulk_delay(),        │
│                                bulk_engagement()                                 │
└───────────────┬──────────────────────────────────────────────▲──────────────────┘
                │ HTTP (wa_get_curl)                            │ MySQL (sp_*)
                ▼                                               │
┌──────────────────────────── wa_serever (Node) ────────────────┴──────────────────┐
│ app.js       GET /health_status  /antiban_resume  /antiban_overview              │
│ waziper/antiban.js   ← fachada sobre a lib baileys-antiban                        │
│   HealthMonitor (por instância, persistido no Redis)                              │
│   JidCanonicalizer (LID ↔ PN)                                                     │
│   PresenceChoreographer (digitação WPM + circadiano)                              │
│   LegitimacySignalInjector (typos)  readReceiptVariance  HumanEntropyService      │
│   rampPresenceAfterConnect (stealth)  generateFingerprint (browser tuple)         │
│   timelockEpisodes (bloqueio síncrono do 463)                                     │
│ waziper/waziper.js   ← integração                                                 │
│   makeWASocket(browser, markOnlineOnConnect)  connection.update  messages.*       │
│   auto_send / process_send_message / bulk_messaging (gates)                       │
│   pauseCampaignsForInstance / resumeAntibanPauses (cron 30 s) / risk alert        │
│ waziper/bulk_queue.js   fila por campanha + ack/leitura/resposta                  │
│ waziper/media_variant.js  imagem com hash único por contato                       │
│ waziper/lid_resolver.js   resolvedor @lid gotejado (opt-in, com disjuntor)        │
└───────────────┬──────────────────────────────────────────────────────────────────┘
                │
        Redis: antiban:health:<id> (6 h)   antiban:timelock:<id> (24 h)
```

## 3. Fluxos principais

### 3.1 Envio (bulk, API, chatbot)

```
bulk_messaging (cron) ─┐
/send_message (API) ───┼─► auto_send()
chatbot/autoresponder ─┘     │ 1. canonicalizeJid (LID→PN)
                             │ 2. isTimelockBlocked? → sai stats:false (não queima contato)
                             │ 3. limit() (cota mensal do plano)
                             │ 4. process_message (spintax/IA)
                             │ 5. isHealthPaused? → sai stats:false
                             │ 6. simulatePresence (digitando/gravando)
                             ▼
                      process_send_message()
                             │ 7. typo humanizado (allowlist)
                             │ 8. unique_media (bulk, se ligado)
                             │ 9. sock.sendMessage
                             ├─ ok    → stats, histórico, BulkQueue.mark(msg_id)
                             ├─ falha transitória (428/408/WS) → stats:false, transient:true
                             └─ falha real → recordMessageFailed + stats:true
```

Antes de chegar ao `auto_send`, o `bulk_messaging` já aplica gates próprios
(socket fechado, timelock, health pause, settle pós-conexão) — ver [05](05-cadencia-bulk.md).

### 3.2 Detecção → pausa → retomada

```
connection.update close ──► Antiban.recordDisconnect(code)
                               ├─ código de infra (428/408/515/503/WS) → ignora no score
                               ├─ demais → HealthMonitor.recordDisconnect → score
                               └─ 401/403 → severeDisconnectAt + handler
                                              └─► pauseCampaignsForInstance('401'|'403')
messages.update stub 463 ──► Antiban.recordReachoutTimelock
                               ├─ HealthMonitor +25
                               └─ timelockEpisodes[id] = cooling (bloqueio síncrono)
                                              └─► pauseCampaignsForInstance('463')

pauseCampaignsForInstance:
   campanhas status=1 da instância → status=0 (grava changed)
   socket.io pause_campaign_<team>
   sp_whatsapp_antiban_alerts (insere ou funde no pendente)
   webhook antiban.timelock_pause | antiban.severe_disconnect

cron */30 s → resumeAntibanPauses():
   fecha alertas órfãos (campanha retomada por fora)
   forced_resume=1 (operador) → retoma
   antiban_auto_resume=1 → retoma se cooldown venceu e tudo saudável
```

Detalhes completos em [03](03-pausa-e-retomada.md).

### 3.3 Humanização do ciclo de vida da conexão

```
makeWASocket(browser = fingerprint(instance_id), markOnlineOnConnect = !stealth)
connection 'open'  → recordReconnect, connectedAt, startEntropy, rampPresence(30–120 s)
messages.upsert DM → markReadHumanized (atraso gaussiano), feedEntropy
connection 'close' → cancelRampPresence; loggedOut → stopEntropy
cron 30 s          → reloadConfig (TTL 60 s) + reconcileEntropy
```

## 4. Princípios de projeto (adotados no código)

1. **Fail-open:** erro de Redis, da lib ou de leitura de config **nunca** bloqueia
   envio nem derruba o processo. Quase toda função de `antiban.js` tem `try/catch` silencioso.
2. **Não queimar contato:** bloqueios do antiban saem com `stats:false` — o contato
   continua pendente na fila e é enviado depois. Só falha real do destinatário conta.
3. **Fonte de verdade = banco:** `sp_whatsapp_schedules.status` + `changed` decide se
   uma pausa ainda é real. Memória (`timelockEpisodes`) e Redis são caches.
4. **Respeitar a intervenção humana:** ao pausar, grava-se `changed`. Se o operador
   mexer na campanha (o `changed` muda), o antiban não religa nada.
5. **Config sem restart:** humanização e timelock leem `sp_options` com TTL
   (60 s / 300 s). Só fingerprint e stealth connect exigem reconexão.
6. **Opt-in por instância:** funções de humanização mais invasivas (typos, read
   receipts, entropy) são allowlist/override por instância; stealth é global ligado.
7. **Pausa automática, retomada manual:** desde 2026-09-10 a retomada automática é
   opt-in (`antiban_auto_resume = 0`), para evitar o loop reconecta → retoma → 403.

## 5. Arquivos-chave (snapshot)

| Arquivo | Papel |
|---|---|
| `wa_serever/waziper/antiban.js` (853 linhas) | Fachada única sobre a lib; todo estado antiban em memória |
| `wa_serever/waziper/waziper.js` (5443 linhas) | Integração: socket, eventos, envio, pausa, retomada, crons |
| `wa_serever/app.js` | Endpoints `/health_status`, `/antiban_resume`, `/antiban_overview` |
| `wa_serever/waziper/bulk_queue.js` | Fila `sp_whatsapp_schedule_recipients` + rastreio de ack/resposta |
| `wa_serever/waziper/media_variant.js` | Hash único por imagem (JPEG COM / PNG tEXt) |
| `wa_serever/waziper/lid_resolver.js` | Resolução @lid via `onWhatsApp` com teto/hora e disjuntor |
| `wa_serever/config.js` (`antiban_humanize`) | Fallback da config de humanização |
| `inc/core/Whatsapp_antiban/` | Central Antiban (admin) |
| `inc/core/Whatsapp_profiles/Controllers/Whatsapp_profiles.php` | Alertas Antiban e ações de pausa |
| `app/Helpers/Common_helper.php` | `bulk_delay_floor`, `validate_bulk_delay`, `bulk_engagement` |
| `inc/core/Whatsapp/Database/Migrations/antiban_*.sql` | Evolução da tabela de alertas |
