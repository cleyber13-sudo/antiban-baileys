# 07 — Banco de dados, configuração e Redis

Prefixo das tabelas nesta instalação: `sp_`. No PHP use as constantes
(`TB_WHATSAPP_ANTIBAN_ALERTS`, `TB_WHATSAPP_SCHEDULE_RECIPIENTS`…), não strings.

## 1. `sp_whatsapp_antiban_alerts`

Schema atual (no projeto: `database_schema/baseline_schema.sql` e as migrations citadas abaixo):

| Coluna | Tipo | Significado |
|---|---|---|
| `id` | int PK | |
| `team_id` | int | dono (filtro de todas as telas) |
| `instance_id` | varchar(50) | = `sp_accounts.token` (mesma collation!) |
| `type` | varchar(20) | `risk` (informativo) · `timelock` (463) · `loggedout` (401) · `forbidden` (403) |
| `risk` | varchar(20) | `medium`/`high`/`critical` |
| `score` | int | score do HealthMonitor (0 nas pausas) |
| `reasons` | text JSON | motivos |
| `recommendation` | text | texto para o operador |
| `active_campaigns` | text JSON | `[{id, name, changed_at}]` — `changed_at` = `changed` gravado na pausa |
| `paused` | tinyint | 1 enquanto a pausa segura campanhas |
| `cooldown_seconds` | int | duração aplicada |
| `resume_at` | int epoch | previsão de retomada |
| `recurrence` | int | reincidência |
| `auto_resume_disabled` | tinyint | 1 = só manual (reincidência alta, re-bloqueio rápido, > 24 h) |
| `manual_hold` | tinyint | 1 = "Manter pausado" |
| `resumed_at` | int epoch | NULL = pausa pendente |
| `forced_resume` | tinyint | 1 = "Retomar agora" |
| `is_read` | tinyint | lido no painel |
| `archived` / `archived_at` | tinyint / int | "Limpar alertas" / "Encerrar sem retomar" |
| `created` | int epoch | |

Índices: `team_id`, `instance_id`, `(type, resumed_at)`, `(team_id, archived)`.

Migrations (em ordem): `antiban_alerts.sql` → `antiban_timelock.sql` →
`antiban_forced_resume.sql` → `antiban_alerts_archive.sql`. Todas não-destrutivas
(`ADD COLUMN` com DEFAULT). Usam o placeholder `TB_WHATSAPP_ANTIBAN_ALERTS`.

## 2. Outras tabelas envolvidas

| Tabela | Colunas relevantes |
|---|---|
| `sp_whatsapp_schedules` | `status` (0 parada, 1 rodando, 2 concluída), `run`, `changed`, `time_post`, `min_delay`, `max_delay`, `accounts` (JSON), `next_account`, `schedule_time`, `presenceType`, `presenceTime`, `unique_media`, `result` |
| `sp_whatsapp_schedule_recipients` | `schedule_id`, `contact_id`, `phone_number_id`, `status` (0 pend., 1 enviado, 2 falha, 3 removido), `instance_id`, `jid`, `msg_id`, `ack`, `sent_at`, `delivered_at`, `read_at`, `replied_at` |
| `sp_accounts` | `token` (= instance_id), `status`, `login_type` (1 = API oficial, 2 = Baileys), `changed` (rotação do `live_back`) |
| `sp_whatsapp_sessions` | `instance_id`, `status` |
| `sp_options` | `name`/`value` — toda a config abaixo |
| `sp_whatsapp_webhook` | destinos dos webhooks `antiban.*` |

## 3. Todas as chaves `sp_options` do antiban

| Chave | Default | Lido por | TTL |
|---|---|---|---|
| `antiban_auto_resume` | 0 | `waziper.js` | 5 min |
| `antiban_timelock_cooldown` | 3600 | `waziper.js` | 5 min |
| `antiban_timelock_backoff_multiplier` | 2 | `waziper.js` | 5 min |
| `antiban_timelock_max_recurrences` | 3 | `waziper.js` | 5 min |
| `antiban_disconnect_cooldown` | 600 | `waziper.js` | 5 min |
| `antiban_quick_reblock_window` | 180 | `waziper.js` | 5 min |
| `antiban_stealth_connect` | 1 | `antiban.js` | 60 s |
| `antiban_stealth_min_ms` / `antiban_stealth_max_ms` | 30000 / 120000 | `antiban.js` | 60 s |
| `antiban_typo_probability` | 0.02 | `antiban.js` | 60 s |
| `antiban_typing_pauses` | 0 | `antiban.js` | 60 s |
| `antiban_typo_instances` | '' | `antiban.js` | 60 s |
| `antiban_read_receipt_instances` | '' | `antiban.js` | 60 s |
| `antiban_read_receipt_mean_ms` / `_stddev_ms` / `_max_ms` | 1500 / 800 / 8000 | `antiban.js` | 60 s |
| `antiban_entropy_instances` | '' | `antiban.js` | 60 s |
| `antiban_entropy_min_hours` / `_max_hours` | 2 / 6 | `antiban.js` | 60 s |
| `antiban_humanize_overrides` | `{}` | `antiban.js` | 60 s |
| `bulk_min_delay_floor` | 8 | PHP + `waziper.js` | 60 s (Node) |
| `bulk_min_delay_gap` | 4 | PHP + `waziper.js` | 60 s (Node) |
| `bulk_settle_seconds` | 120 | `waziper.js` | 60 s |
| `bulk_queue_legacy` | 0 | `bulk_queue.js` | 60 s |

Formato do override:

```json
{ "INSTANCIA_B": { "typos": 0, "read_receipts": 1, "entropy": 1, "stealth": 1 } }
```

> `get_option()` do PHP **insere** a chave com o default se ela não existir.
> Abrir a Central Antiban materializa todas as `GLOBAL_KEYS`.

## 4. `wa_serever/config.js` → `antiban_humanize` (fallback)

```js
antiban_humanize: {
  enabled_instances: [],        // typos: [] | ['ID',...] | '*'
  typo_probability: 0.02,
  typing_pauses: false,
  read_receipt_instances: [],
  read_receipt_mean_ms: 1500, read_receipt_stddev_ms: 800, read_receipt_max_ms: 8000,
  entropy_instances: [],
  entropy_min_hours: 2, entropy_max_hours: 6,
  stealth_connect: true, stealth_min_ms: 30000, stealth_max_ms: 120000,
},
lid_resolver: { enabled_instances, per_hour: 6, window_start_hour: 8, window_end_hour: 21,
                min_gap_ms: 240000, max_gap_ms: 1080000, abort_keep_hours: 720, max_queue: 20000 },
```

Só vale quando a chave correspondente **não existe** em `sp_options`.

## 5. Redis

| Chave | TTL | Escrito por |
|---|---|---|
| `antiban:health:<instance_id>` | 6 h | `antiban.js persistHealth()` |
| `antiban:timelock:<instance_id>` | 24 h | `antiban.js persistTimelock()` |

```bash
redis-cli --scan --pattern 'antiban:*'
redis-cli get antiban:health:INSTANCIA_B | jq .
```

## 6. Webhooks emitidos (`WAZIPER.webhook`)

| Evento | Quando | `data` |
|---|---|---|
| `antiban.risk_alert` | risco sobe para `high`/`critical` | `instance_id, paused, active_campaigns, risk, score, reasons, recommendation, stats` |
| `antiban.timelock_pause` | pausa nova por 463 | `instance_id, type, reason, recurrence, cooldown_seconds, resume_at, auto_resume_disabled, campaigns` |
| `antiban.severe_disconnect` | pausa nova por 401/403 | idem |
| `antiban.timelock_resume` | retomada (auto ou forçada) de qualquer tipo | `episode_id, type, forced, campaigns` |

O alerta `risk` é deduplicado: não grava outro do mesmo nível para a mesma
instância dentro de 1 h. Pausas fundidas não reemitem webhook.

## 7. Socket.io (tempo real no painel)

- `pause_campaign_<team_id>` `{ id, status: 0 }`
- `resume_campaign_<team_id>` `{ id, status: 1 }`

O handler do painel atualiza só um `<span>` interno da célula de status
(`setBulkStatus()`), para não apagar o botão pausar/retomar.
