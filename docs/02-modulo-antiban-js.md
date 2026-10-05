# 02 — Módulo `wa_serever/waziper/antiban.js`

Fachada CommonJS sobre a `baileys-antiban`. Todo o estado antiban **por
instância** vive aqui, em memória, espelhado no Redis quando faz sentido.
O `waziper.js` nunca usa a lib diretamente — sempre via `Antiban.*`.

```js
const { JidCanonicalizer, HealthMonitor, PresenceChoreographer,
        LegitimacySignalInjector, generateFingerprint, readReceiptVariance,
        HumanEntropyService, rampPresenceAfterConnect, AbortError } = require("baileys-antiban");
```

## 1. Estado em memória

| Variável | Chave | Conteúdo |
|---|---|---|
| `healthMonitors` | instance_id | `HealthMonitor` (score de risco) |
| `canonicalizers` | instance_id | `JidCanonicalizer({ enabled:true, canonical:'pn' })` |
| `timelockEpisodes` | instance_id | `{ phase:'cooling'|'resumed', recurrence, hits, since, resumedAt? }` |
| `severeDisconnectAt` | instance_id | `Date.now()` do último 401/403 (backoff de 10 min) |
| `entropyServices` | instance_id | `{ service: HumanEntropyService, bus: EventEmitter }` |
| `stealthAborters` | instance_id | `AbortController` da rampa de presença pendente |
| `HCFG` | — | config de humanização efetiva (ver §4) |
| `choreographer` | — | `PresenceChoreographer` único (45 WPM ± 15, circadiano `America/Sao_Paulo`) |
| `legitimacy`, `rrVariance` | — | injetores reconstruídos a cada reload de config |

Handlers registrados pelo `waziper.js` (evita dependência circular):
`riskAlertHandler`, `timelockHandler`, `severeDisconnectHandler`, `entropySocketResolver`.

## 2. Persistência no Redis

Mesma URL de `config.redis` (conexão `ioredis` própria). Erro de Redis só gera
`console.warn` — o antiban continua só em memória.

| Chave | TTL | Conteúdo | Quando grava |
|---|---|---|---|
| `antiban:health:<instance_id>` | 6 h | `{events, startTime, paused, lastRisk, lastBadEventTime, lastEventWasSevere}` | após cada evento do HealthMonitor |
| `antiban:timelock:<instance_id>` | 24 h | episódio de timelock | a cada mudança do episódio (deleta quando limpa) |

`restoreHealth()` reidrata o monitor na primeira vez que ele é criado no processo.
O episódio de timelock é reidratado **do banco** no boot (`restoreAntibanPausesFromDB`).

## 3. API exportada

### 3.1 Identidade e conexão

| Função | Descrição |
|---|---|
| `deviceFingerprint(id)` | Tupla `browser` `[OS, 'Chrome', versão]` **determinística** pelo `instance_id` (PRNG mulberry32 da lib). OS ∈ Windows/Mac OS/Linux, Chrome 122–133. Fallback `['Linux','Chrome','131.0.6778.86']`. |
| `stealthConnectEnabled(id)` | `true` → `makeWASocket({ markOnlineOnConnect:false })` |
| `rampPresence(sock, id)` | Agenda `available` após `stealth_min_ms`–`stealth_max_ms` (30–120 s), cancelável |
| `cancelRampPresence(id)` | Aborta a rampa (chamado no `close` e no `logout()`) |
| `canonicalizeJid(id, jid)` | LID → PN se o mapeamento for conhecido (evita Bad MAC) |
| `learnFromUpsert(id, upsert)` | Aprende mapeamentos LID↔PN dos eventos recebidos |

### 3.2 Saúde e risco

| Função | Descrição |
|---|---|
| `recordDisconnect(id, reason)` | Filtra `INFRA_DISCONNECT_CODES` (428, 408, 515, 503, 1000, 1001, 1005, 1006, unknown, undefined) — **esses não pontuam**. Os demais vão pro HealthMonitor. 401/loggedOut/403/forbidden marcam `severeDisconnectAt` e chamam `severeDisconnectHandler(id,'401'|'403')`. |
| `recordReconnect(id)` | Evento de reconexão; limpa o backoff severo |
| `recordMessageFailed(id, msg)` | Falha **real** de envio (transitórias não chegam aqui) |
| `recordReachoutTimelock(id, detail)` | +25 no score **e** abre/atualiza episódio de timelock (ver §5) |
| `isHealthPaused(id)` | `HealthMonitor.isPaused()` (pausa em `autoPauseAt:'high'`) |
| `getHealthStatus(id)` | `{ risk, score, reasons, recommendation, stats }` |
| `forceHealthResume(id)` | `monitor.reset()` + limpa backoff severo (usado na retomada forçada) |
| `severeReconnectBackoffMs(id)` | ms restantes do backoff pós-401/403 (10 min); 0 = liberado |
| `setRiskAlertHandler(fn)` | `fn(id, status)` em toda mudança de nível de risco |

### 3.3 Timelock (463)

| Função | Descrição |
|---|---|
| `isTimelockBlocked(id)` | **Síncrono**: `phase === 'cooling'`. Consultado por `auto_send` e `bulk_messaging` |
| `getTimelockEpisode(id)` | Episódio atual ou `null` |
| `markTimelockResumed(id)` | `phase='resumed'` (mantém `recurrence` para detectar reincidência) |
| `clearTimelockEpisode(id)` | Remove de vez (memória + Redis) |
| `restoreTimelockEpisode(id, data)` | Reidratação no boot |
| `setTimelockHandler(fn)` / `setSevereDisconnectHandler(fn)` | Callbacks do `waziper.js` |

### 3.4 Humanização

| Função | Descrição |
|---|---|
| `reloadConfig(force)` | Recarrega `HCFG` de `sp_options` (TTL 60 s; `force` ignora TTL) |
| `effectiveFlags(id)` | `{ typos, read_receipts, entropy, stealth, has_override }` |
| `humanizeEnabled(id)` | flag efetiva de typos |
| `humanizeText(id, text)` | `{ typoText, correctionDelay, correctionText }` ou `null` |
| `readReceiptEnabled(id)` | flag efetiva de read receipts |
| `markReadHumanized(sock, id, keys, ts)` | `readMessages` com atraso gaussiano; backlog (> 60 s) marca na hora. Fire-and-forget |
| `setEntropySocketResolver(fn)` | `fn(id)` → socket vivo atual |
| `startEntropy(id)` / `stopEntropy(id)` | Ciclo de vida do `HumanEntropyService` |
| `feedEntropy(id, message)` | Alimenta contatos recentes (só DM recebida) |
| `getEntropyStats(id)` | Estatísticas do serviço |
| `reconcileEntropy(ids)` | Liga/desliga conforme flag; para serviços de instâncias sumidas |
| `simulatePresence(sock, chat_id, item)` | `presenceType` 1 = digitando (plano WPM reescalado para `presenceTime`), 2 = gravando (`presenceTime` fixo, default 5 s) |

## 4. Configuração de humanização (`HCFG`)

Ordem de precedência: **`sp_options` (painel) → `config.js antiban_humanize` → default**.

| Campo HCFG | Chave `sp_options` | config.js | Default |
|---|---|---|---|
| `stealth_connect` | `antiban_stealth_connect` | `stealth_connect` | `true` |
| `stealth_min_ms` / `stealth_max_ms` | `antiban_stealth_min_ms` / `_max_ms` | idem | 30000 / 120000 |
| `typo_probability` | `antiban_typo_probability` | `typo_probability` | 0.02 |
| `typing_pauses` | `antiban_typing_pauses` | `typing_pauses` | false |
| `rr_mean_ms` / `rr_stddev_ms` / `rr_max_ms` | `antiban_read_receipt_mean_ms` / `_stddev_ms` / `_max_ms` | `read_receipt_*` | 1500 / 800 / 8000 |
| `entropy_min_hours` / `entropy_max_hours` | `antiban_entropy_min_hours` / `_max_hours` | idem | 2 / 6 |
| `typo_allow` | `antiban_typo_instances` | `enabled_instances` | `[]` |
| `rr_allow` | `antiban_read_receipt_instances` | `read_receipt_instances` | `[]` |
| `entropy_allow` | `antiban_entropy_instances` | `entropy_instances` | `[]` |
| `overrides` | `antiban_humanize_overrides` (JSON) | — | `{}` |

Allowlist: string `'a,b'`, `'*'` (todas) ou `''` (ninguém). Linha ausente no
banco (`null`) → cai no `config.js`.

**Flag efetiva** (`effectiveFlag(id, fn)`): override da instância
(`overrides[id][fn]` ∈ 0/1) **>** allowlist global (typos/read_receipts/entropy)
ou `stealth_connect` global (stealth).

Carga atômica: lê todas as chaves; se **qualquer** SELECT falhar, mantém a config
anterior (não cai para default achando que a chave não existe). `hcfgLoading`
evita corrida entre a carga do boot e o cron.

`enableReadGaps` da lib fica **sempre desligado** (atraso de 5–60 min antes de
enviar é incompatível com disparo).

## 5. Episódio de timelock (463)

```
recordReachoutTimelock(id):
  ep = timelockEpisodes[id]
  se ep.phase == 'cooling'  → ep.hits++ (dedup; não recria pausa)        ; fim
  recurrence = ep.phase == 'resumed' ? ep.recurrence + 1 : 1
  timelockEpisodes[id] = { phase:'cooling', recurrence, hits:1, since:now }
  persistTimelock(id)
  timelockHandler(id, { recurrence })   → waziper.pauseCampaignsForInstance(id,'463')
```

## 6. Presença (`simulatePresence`)

- `presenceType = 1` (digitando): `presenceSubscribe` → 300 ms →
  `choreographer.computeTypingPlan(len(caption) || 60)` → plano **reescalado**
  para somar exatamente `presenceTime * 1000` ms → passos iguais seguidos são
  mesclados e pausas < 400 ms viram digitação (menos presence updates) →
  `executeTypingPlan` → `paused`. `presenceTime <= 0` = sem digitação.
- `presenceType = 2` (gravando): `recording` por `presenceTime` s (default 5) → `paused`.
- O painel (`Whatsapp_bulk/Views/update.php`) só **sugere** o tempo: `len / 3,75`
  caracteres/s, limitado a 2–25 s.

## 7. Garantias de robustez

- Nenhuma função exportada lança exceção para o chamador.
- `markReadHumanized`, `rampPresence`, `persist*` são fire-and-forget.
- O `HumanEntropyService` resolve o socket a cada ciclo (sobrevive a reconexão).
- Um `EventEmitter` por instância → `stopEntropy` remove tudo sem vazar listener.
