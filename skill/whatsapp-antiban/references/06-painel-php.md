# 06 — Painel PHP

Duas telas tratam do antiban, com públicos diferentes:

| Tela | Módulo | Público | Função |
|---|---|---|---|
| **Central Antiban** | `inc/core/Whatsapp_antiban` | admin (`role => 1`) | configurar humanização e retomada, ver risco por instância |
| **Alertas Antiban** | `inc/core/Whatsapp_profiles` (`antiban_alerts`) | cada time | ver e agir sobre pausas e alertas de risco |

## 1. Central Antiban (`Whatsapp_antiban`)

`Config.php`: id `whatsapp_antiban`, ícone `fad fa-shield-check`, menu topo
posição 950, `role => 1` (bloqueado para não-admin pelo `Auth/Filters/beforeFilter.php`;
o controller tem `guard()` como defesa em profundidade).

### Ações do controller

| Rota | Método | O que faz |
|---|---|---|
| `whatsapp_antiban` | `index()` | Lê `GLOBAL_KEYS` de `sp_options`, overrides, contas, `bulk_engagement` (7 dias) |
| `whatsapp_antiban/save` | `save()` | Grava as chaves globais (booleans normalizados para `'0'/'1'`, allowlists sanitizadas por `clean_allowlist`, números validados) |
| `whatsapp_antiban/override/<instance_id>` | `override()` | POST `{function, value}` com `value` ∈ `1`/`0`/`inherit`; atualiza o JSON `antiban_humanize_overrides` |
| `whatsapp_antiban/overview` | `overview()` | Proxy de `GET /antiban_overview?all=1` do wa_serever (polling da tabela) |

`GLOBAL_KEYS` (e defaults): `antiban_auto_resume` `'0'`, `antiban_stealth_connect` `'1'`,
`antiban_typo_probability` `'0.02'`, `antiban_typo_instances` `''`,
`antiban_read_receipt_instances` `''`, `antiban_entropy_instances` `''`,
`antiban_read_receipt_mean_ms` `'1500'`, `antiban_read_receipt_max_ms` `'8000'`,
`antiban_entropy_min_hours` `'2'`, `antiban_entropy_max_hours` `'6'`.

`clean_allowlist`: `'*'` passa; senão só IDs `^[A-Za-z0-9_-]{4,64}$`, deduplicados.

### Layout

- **Card Global:** toggle "Retomada automática de campanhas", toggle "Stealth connect",
  probabilidade de typo, allowlists (typos / read receipts / atividade de fundo),
  atrasos de leitura e intervalo de ciclo do entropy.
- **Tabela Por instância:** nome/número/token, Conectado, Risco (via overview),
  Entrega/respostas (7d), e um select por função (`Herdar global` / `Ligado` /
  `Desligado`) com a flag efetiva calculada abaixo.
- Aviso: "aplica em ~1 min (sem restart); fingerprint e stealth na próxima reconexão".

JS: `Assets/js/whatsapp_antiban.js` (polling do overview e POST de override).

## 2. Alertas Antiban (`Whatsapp_profiles`)

Contador de não lidos no topo da lista de perfis
(`Whatsapp_profilesModel`: `is_read=0 AND archived=0`).

### Listagem — `antiban_alerts()`

- Do time atual, `archived = 0`.
- Pausas reais (`timelock`, `loggedout`, `forbidden`) **sempre**; alertas `risk` só
  dos últimos `RISK_ALERT_RETENTION_DAYS` (7) dias. Limite 100, mais recentes primeiro.
- JOIN com `sp_accounts` (nome/número). Collation de `instance_id` igual à de
  `sp_accounts.token` (utf8mb4_general_ci) — senão "Illegal mix of collations".
- Reconcilia órfãos antes de renderizar (`antiban_pause_still_active`).
- View: `Views/antiban_alerts.php` (seção "Pausas ativas" com contagem regressiva e
  botões; lista de alertas de risco com motivos e recomendação).

### Ações

| Rota | Método | Ver |
|---|---|---|
| `whatsapp_profiles/timelock_release/<id>` | "Retomar agora" | [03 §5](03-pausa-e-retomada.md) |
| `whatsapp_profiles/timelock_hold/<id>` | "Manter pausado" (toggle) | |
| `whatsapp_profiles/antiban_dismiss/<id>` | "Encerrar sem retomar" | |
| `whatsapp_profiles/clear_alerts` | "Limpar alertas" | |
| `whatsapp_profiles/mark_alert_read/<id|all>` | marcar lido | |
| `whatsapp_profiles/antiban_status` | polling JSON | `{status, now, pauses:[{id,resume_at,remaining,manual_hold,auto_resume_disabled,forced_resume}]}` |

Todas filtram por `team_id = get_team("id")`.

> **CSRF:** POSTs feitos à mão (fetch/ajax) nessas views precisam enviar o token
> `csrf` global — sem ele o CodeIgniter devolve 500 e o front mostra
> "Resposta não é JSON válido".

### Ao excluir uma instância

O `delete` de `Whatsapp_profiles` arquiva os alertas antiban abertos da instância
(`resumed_at`, `archived=1`) e chama `/antiban_resume` para soltar o bloqueio 463
em memória — senão o alerta fica órfão no painel e o cron segue lendo. As
campanhas não são tocadas (continuam em `status=0`).

## 3. Bulk (`Whatsapp_bulk`)

- `save()` chama `validate_bulk_delay()` (piso 8 s / gap 4 s).
- Formulário: "Presence Delay" (`presenceType` Nenhum/Digitando/Gravando, default
  Digitando) + `presenceTime` com "Tempo de digitação sugerido" e link "Usar sugestão".
- Toggle "Imagem única por contato" (`unique_media`).
- Lista de campanhas: coluna "Engajamento" (`bulk_engagement` por `schedule_id`).
- `status()` (pausar/retomar manual) grava `changed` — é isso que faz o antiban
  respeitar a intervenção humana.

## 4. Endpoints do wa_serever usados pelo painel

| Endpoint | Auth | Uso |
|---|---|---|
| `GET /health_status?access_token&instance_id` | `WAZIPER.instance` | `{ instance_id, paused, risk, score, reasons, recommendation, stats }` |
| `GET /antiban_resume?access_token` | `sp_team.ids` | dispara `triggerAntibanResume()` (não cria/toca sessão) |
| `GET /antiban_overview?access_token[&all=1]` | `sp_team.ids` | por instância: `connected`, `health`, `entropy` (stats), `flags` efetivas |
