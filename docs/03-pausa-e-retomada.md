# 03 — Pausa real e retomada

O `HealthMonitor` da lib só **pontua** risco. A pausa que de fato para campanhas
é uma camada própria do projeto, em `waziper.js`, alimentada por `antiban.js`.

## 1. Gatilhos

| Evento | Detecção | Tipo do alerta | Risco gravado |
|---|---|---|---|
| **463 reachout timelock** | `messages.update` com `messageStubParameters` contendo `463` → `Antiban.recordReachoutTimelock` | `timelock` | `high` |
| **401 loggedOut** | `connection.update` close, `statusCode` 401 → `pauseCampaignsForInstance(id,'401')` (com `await`, **antes** de apagar/recriar a sessão) | `loggedout` | `critical` |
| **403 forbidden** | idem, 403 | `forbidden` | `critical` |
| **Risco alto/crítico** | `HealthMonitor.onRiskChange` → `riskAlertHandler` | `risk` (informativo) | `high`/`critical` |

O alerta `risk` **não pausa** campanha: ele só registra e avisa. Quem segura o
envio por risco é o `isHealthPaused()` nos gates (contato não é queimado).

Ao fechar com 401/403, além de pausar, o `waziper.js` grava `sp_accounts.status=0`
e `sp_whatsapp_sessions.status=0` (corrige o "Conectado" fantasma no painel).

## 2. `pauseCampaignsForInstance(instance_id, reason, opts)`

1. `loadAntibanTimelockConfig()` (TTL 5 min).
2. **Cooldown:**
   - `timelock`: `cooldown = antiban_timelock_cooldown × multiplier^(recurrence−1)`
     (3600 s, 7200 s, 14400 s…). `recurrence > max_recurrences (3)` → `auto_resume_disabled=1`.
   - `loggedout`/`forbidden`: `cooldown = antiban_disconnect_cooldown` (600 s).
     `recurrence` = nº de pausas 401/403 da instância na última hora + 1.
     **Anti ping-pong:** se a última pausa foi retomada há ≤ `antiban_quick_reblock_window`
     (180 s) → `auto_resume_disabled=1` e recomendação "reconecte ou troque o número".
3. Campanhas **rodando** (`status=1`) que usam a conta → `status=0, run=0, changed=now`.
   Campanhas já pausadas ficam intocadas (respeita pausa manual anterior).
   Emite `pause_campaign_<team_id>` via socket.io.
4. **Fusão por instância:** se já existe alerta pendente (`resumed_at IS NULL`) da
   instância, funde: une campanhas, maior `resume_at`/`cooldown`/`recurrence`, tipo
   mais severo (`forbidden`/`loggedout` = 2 > `timelock` = 1). Não cria 2º card.
5. Senão, insere em `sp_whatsapp_antiban_alerts` e dispara webhook
   `antiban.timelock_pause` ou `antiban.severe_disconnect`.

## 3. Bloqueio durante a pausa

| Ponto | Verificação | Efeito |
|---|---|---|
| `bulk_messaging` | `isTimelockBlocked(id)` | `break` (cobre a janela entre o 463 e o UPDATE status=0) |
| `bulk_messaging` | `isHealthPaused(id)` | pula a conta (`next_account+1, run:0`) sem consumir contato |
| `auto_send` | `isTimelockBlocked(id)` | `callback({ status:0, stats:false })` — mensagem preservada |
| `auto_send` | `isHealthPaused(id)` | `stats:false` (antes de 2026-09-24 queimava o contato) |
| `live_back` | `severeReconnectBackoffMs(id) > 0` | não recria socket (cada recriação gerava novo 403) |
| LidResolver worker | `isHealthPaused(id)` | não faz lookup |

## 4. Retomada — `resumeAntibanPauses()` (cron a cada 30 s)

Trava compartilhada `resumeAntibanRunning` com o gatilho manual
(`WAZIPER.triggerAntibanResume`, chamado por `GET /antiban_resume`).

Para cada alerta `timelock|loggedout|forbidden` com `resumed_at IS NULL`, em ordem:

1. **Reconciliação de órfãos:** se nenhuma campanha do alerta está mais em
   `status=0` **com o mesmo `changed`** gravado na pausa → fecha o alerta
   (`resumed_at=now, paused=0`), `markTimelockResumed` se for 463. Não religa nada.
2. `forced = (forced_resume == 1)`.
3. Se **não** forçado e `antiban_auto_resume = 0` (default) → pula. **Fim da linha
   para a retomada automática.**
4. Não forçado: pula se `manual_hold=1` ou `auto_resume_disabled=1`.
5. Pula se `resume_at > now` (o "Retomar agora" puxa `resume_at` para `now`).
6. Não forçado e alerta com mais de `maxPendingHours` (24 h) → `auto_resume_disabled=1`.
7. Sem socket em memória (`sessions[id]`) → pula (inclusive forçado; tenta de novo no próximo ciclo).
8. `isHealthPaused(id)`: não forçado → pula; forçado → `forceHealthResume(id)` (reset do score).
9. Não forçado: pula se houver **outro** episódio pendente bloqueante da mesma instância.
10. Para cada campanha: só religa se ainda `status=0` e `changed` igual ao da pausa →
    `status=1, run=0, time_post = now + bulk_delay(...)`, `changed=now`;
    emite `resume_campaign_<team_id>`.
11. Fecha o alerta, `markTimelockResumed` (463), webhook `antiban.timelock_resume`
    `{ episode_id, type, forced, campaigns }`.

### Boot

`restoreAntibanPausesFromDB()` reidrata `timelockEpisodes` (fase `cooling`) a partir
dos alertas `timelock` pendentes — o bloqueio sobrevive a `pm2 restart`.

## 5. Ações do operador (painel → `Whatsapp_profiles`)

| Botão | Método | Efeito no banco | Observação |
|---|---|---|---|
| **Retomar agora** | `timelock_release($id)` | `manual_hold=0, auto_resume_disabled=0, forced_resume=1, resume_at=now` + `GET /antiban_resume` | Ignora risco/reincidência/tempo; exige socket vivo e respeita pausa manual da campanha |
| **Manter pausado** | `timelock_hold($id)` | alterna `manual_hold` | Só tem efeito com auto-resume ligado |
| **Encerrar sem retomar** | `antiban_dismiss($id)` | `resumed_at=now, paused=0, archived=1` | Campanhas ficam em `status=0`; libera o bloqueio 463 em memória via `/antiban_resume` |
| **Limpar alertas** | `clear_alerts()` | `archived=1` em encerrados/antigos/inconsistentes | Nunca arquiva pausa que ainda segura campanha; 463 sem campanha < 24 h também é protegido |
| Marcar lido | `mark_alert_read($id|'all')` | `is_read=1` | Badge de não lidos |
| Polling | `antiban_status()` | — | JSON das pausas ativas para atualizar os cards |

O PHP também reconcilia órfãos ao listar (`antiban_pause_still_active`), exceto
`timelock`, cujo estado em memória só o Node sabe finalizar.

## 6. Máquina de estados de um alerta de pausa

```
                     463 / 401 / 403
                          │
                          ▼
                 ┌─────────────────┐  novo 401/403/463 da mesma instância
                 │  PENDENTE       │◄──────── (fusão: tipo mais severo, maior resume_at)
                 │ resumed_at NULL │
                 │ paused = 1      │
                 └──┬──────┬───┬───┘
   campanha mexida  │      │   │ "Encerrar sem retomar"
   por fora         │      │   └──────────────► ENCERRADO + ARQUIVADO
   (órfão)          │      │                    (campanhas continuam paradas)
                    ▼      │ forced_resume=1  (ou auto_resume=1 + cooldown + saudável)
            FECHADO (órfão)│
                           ▼
                 ┌─────────────────┐
                 │ RETOMADO        │ resumed_at = now, paused = 0
                 │ campanhas status=1
                 └─────────────────┘
                          │ "Limpar alertas"
                          ▼
                      ARQUIVADO
```

Episódio 463 em memória: `cooling` → (retomada/encerramento) → `resumed` → novo 463
→ `cooling` com `recurrence+1` → cooldown dobra.

## 7. Configuração (`sp_options`)

| Chave | Default | Uso |
|---|---|---|
| `antiban_auto_resume` | `0` | 1 = retomada automática (opt-in desde 2026-09-10) |
| `antiban_timelock_cooldown` | 3600 s | pausa base do 463 |
| `antiban_timelock_backoff_multiplier` | 2 | cooldown × mult^(n−1) |
| `antiban_timelock_max_recurrences` | 3 | acima disso: só manual |
| `antiban_disconnect_cooldown` | 600 s | pausa por 401/403 |
| `antiban_quick_reblock_window` | 180 s | 401/403 até X s após retomada → só manual |
| (código) `maxPendingHours` | 24 h | desiste da retomada automática |
| (código) `SEVERE_RECONNECT_BACKOFF_MS` | 10 min | `live_back` não recria socket |

Valores ≤ 0 ou não numéricos caem no default. TTL de leitura: 5 min.

## 8. Por que o desenho é assim (lições de produção)

- **2026-08-28** — uma instância (INSTANCIA_C) levou loggedOut no meio de campanha
  sem pausa nenhuma: o 463 só somava +25 no score. Nasceu a pausa real.
- **2026-08-31** — "Retomar agora" ficava preso: o cron barrava por `isHealthPaused`
  (o próprio 403 mantinha o score alto) e `blockingOther`. Nasceu `forced_resume`
  com reset do HealthMonitor + polling do painel + backoff do `live_back`.
- **2026-09-10** — loop reconecta → retoma → 403 → repausa na instância INSTANCIA_A.
  Retomada automática virou opt-in.
- **2026-09-24** — pausa por risco queimava contatos (`stats:true`) e o score era
  contaminado por quedas de infraestrutura (428 dominava). Corrigido: `stats:false`
  + `INFRA_DISCONNECT_CODES`.
