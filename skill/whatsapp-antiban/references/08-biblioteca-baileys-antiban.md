# 08 — Biblioteca `baileys-antiban` (referência em PT-BR)

- Repositório: <https://github.com/kobie3717/baileys-antiban> · npm `baileys-antiban`
- Versão analisada: **4.10.0** (2026-06-11, commit `0c80950`) — a mesma instalada em
  `wa_serever/node_modules`.
- Licença MIT, autor Kobus Wentzel (usa em produção no WhatsAuction).
- TypeScript, ESM + CJS (`dist/cjs`), Node ≥ 16, sem telemetria, releases assinados
  (SLSA/Sigstore). Funciona com Baileys e `@oxidezap/baileyrs`.

Documentos originais copiados em [`biblioteca/baileys-antiban/`](../biblioteca/baileys-antiban/).

> **Atenção às divergências README × código** (marcadas com ⚠️ abaixo). Quando
> houver conflito, vale o código (`src/`).

## 1. Formas de uso

### 1.1 `wrapSocket()` — envelope automático

```ts
import { wrapSocket } from 'baileys-antiban';
const sock = wrapSocket(makeWASocket({...}), { preset: 'moderate' }, warmUpState?, {
  deafSession?, autoRespondToIncoming?, groupOpGuard?, legitimacySignals?,
  circuitBreaker?, fleetEventStore?,
});
sock.antiban.getStats();
```

Intercepta `sendMessage` (aplica `beforeSend`/`afterSend` e a espera recomendada),
liga por padrão GroupOperationGuard e LegitimacySignalInjector, e expõe `sock.antiban`.
`wrapSocketWithFingerprint(makeWASocket, config, opts)` faz o mesmo + fingerprint aleatório.

### 1.2 `AntiBan` — controle manual

```ts
const ab = new AntiBan('moderate' | { preset, ...overrides }, warmUpState?);
const d = await ab.beforeSend(jid, text);   // { allowed, delayMs, reason, health, warmUpDay }
if (d.allowed) { await sleep(d.delayMs); await sock.sendMessage(...); ab.afterSend(jid, text); }
else ...;
ab.afterSendFailed(err.message);
ab.onDisconnect(statusCode); ab.onReconnect();
ab.pause(); ab.resume(); ab.reset(); ab.getStats(); ab.exportState(); ab.importState(s);
```

**Ordem das checagens do `beforeSend`** (código): health pausado → BanRecovery em
`paused` → TimelockGuard (bloqueia só contato novo) → WarmUp diário → ContactGraph →
TopologyThrottler (DM para contato novo) → avaliação de risco do contato (abort/delay)
→ ReplyRatio → PostReconnectThrottle → InstanceCoordinator (orçamento por IP) →
perfil de grupo → RateLimiter (`getDelay`).

### 1.3 Módulos avulsos

Todos os módulos são exportados e podem ser usados isoladamente (é o que o
projeto faz — ver [09](09-lib-vs-projeto.md)).

## 2. Presets (`src/presets.ts`)

| Campo | conservative | moderate | aggressive | high-volume |
|---|---|---|---|---|
| maxPerMinute | 5 | 10 | 20 | 40 |
| maxPerHour | 100 | 300 | 800 | 1500 |
| maxPerDay | 800 | 1500 | 4000 | 8000 |
| minDelayMs / maxDelayMs | 2500 / 7000 | 1500 / 5000 | 800 / 3000 | 400 / 1800 |
| newChatDelayMs | 4000 | 3000 | 2000 | 1200 |
| maxIdenticalMessages (1 h) | 3 | 5 | 10 | 20 |
| burstAllowance | 3 | 5 | 8 | 15 |
| warmupDays / day1Limit / growth | 10 / 15 / 1.8 | 7 / 20 / 1.8 | 4 / 35 / 2.0 | 3 / 60 / 2.5 |
| inactivityThresholdHours | 72 | 72 | 48 | 24 |
| autoPauseAt | **medium** | high | high | high |
| groupMultiplier | 0.5 | 0.7 | 0.9 | 0.95 |

Sem argumento, `new AntiBan()` usa **conservative**. `high-volume` só para contas
com 6+ meses e sem ban.

## 3. Módulos

### 3.1 Saúde e risco

**HealthMonitor** (`health.ts`) — usado pelo projeto.
- Eventos: `recordDisconnect(reason)`, `recordReconnect()`, `recordMessageFailed()`,
  `recordReachoutTimelock()`. `getStatus()`, `isPaused()`, `setPaused()`, `reset()`.
- Pontuação na janela de 1 h: 403 = **+40 cada**; 401 = +60; 463 = +25;
  quedas ≥ 3/h (warning) **ou** ≥ 5/h (critical) = +30; falhas ≥ 5/h = +20; teto 100.
- **Decaimento:** −2 pts/min se o último evento ruim foi severo (401/403), senão −5 pts/min.
- ⚠️ **Faixas reais no código:** `low` < 15 ≤ `medium` < 40 ≤ `high` < 80 ≤ `critical`.
  (O README diz 0–29 / 30–59 / 60–84 / 85–100 — está desatualizado.)
- Recomendações: medium "reduza 50 %", high "reduza 80 %, considere pausar 1–2 h",
  critical "PARE TUDO, desconecte e espere 24–48 h".
- Pausa automática ao atingir `autoPauseAt`; `onRiskChange(status)` a cada mudança.
- Conta **todo** código ≠ 401/403 como "disconnect" — por isso o projeto filtra
  quedas de infraestrutura antes (ver [09 §3](09-lib-vs-projeto.md)).

**SessionHealthMonitor / wrapWithSessionStability** (`sessionStability.ts`) — razão de
sucesso de descriptografia, alerta após N Bad MAC em 60 s (`onDegraded`/`onRecovered`).

**classifyDisconnect(code)** → `{ category: fatal|recoverable|rate-limited|unknown, shouldReconnect, backoffMs, message }`.
⚠️ Classificação da lib: 401/440 fatal; **515 fatal**; 405 fatal; **409/428 fatal
("connection replaced")**; 412 recuperável 30 s; 429 rate-limited 5 min; 503 rate-limited
1 min; 408 recuperável 5 s; 500 recuperável 10 s; 1000 recuperável 2 s; resto unknown 15 s.
No enum do Baileys, **428 = connectionClosed** e **515 = restartRequired** (normal após
pareamento) — **não use essa classificação para decidir reconexão sem revisar**.

**DeliveryTracker** (`deliveryTracker.ts`) — razão ✓✓/enviadas numa janela de 1 h,
amostra mínima 10, `lowRateThreshold` 0,6 → `onLowDeliveryRate`. Alimentar com
`messages.upsert` (fromMe) e `messages.update` (`status >= 3`).

**RetryReasonTracker** (`retryTracker.ts`, `retryReason.ts`) — motivos de retry
(no_session, invalid_key, bad_mac, server_error_463/429, timeout…) e detecção de
"espiral" de retry.

**Observability** (`observability.ts`) — logger estruturado + handler Prometheus
(`createMetricsHandler(() => antiban.getStats())`).

**WebhookAlerts** (`webhooks.ts`) — Telegram, Discord, Slack, URLs, `minRiskLevel`.

### 3.2 Ritmo e volume

**RateLimiter** (`rateLimiter.ts`) — defaults standalone 8/min, 200/h, 1500/dia,
1,5–5 s. Jitter **gaussiano** (concentra no meio da faixa), ~30 ms por caractere,
penalidade de primeiro contato, `burstAllowance`, bloqueio de mensagens idênticas
(1 h). **Adaptativo** (v4.5): entrega ≥ 85 % → 100 % da velocidade; < 55 % → 25 %.
`adaptLimits(factor)`, `getCurrentFactor()`.

**WarmUp** (`warmup.ts`) — 7 dias, dia 1 = 20, `growthFactor` **aleatório 1,5–2,2**
por padrão (o README mostra 1,8 fixo: 20, 36, 65, 117, 210, 378, 680, depois livre).
Volta ao aquecimento após 72 h inativo. Persistir com `exportWarmUpState()`.

**PostReconnectThrottle** (`reconnectThrottle.ts`, opt-in) — após reconectar, começa
em 10 % e sobe em 6 degraus por 60 s.

**InstanceCoordinator** (`instanceCoordinator.ts`) — token bucket compartilhado entre
processos via arquivo JSON (rename atômico): ex. 20/min e 500/h por IP.
Resolve "5 bots × 8/min no mesmo IP = 40/min".

**Scheduler** (`scheduler.ts`) — horário ativo (ex. 8–21 h), fator de fim de semana,
pico e almoço; `isActiveTime()`, `adjustDelay()`, `msUntilActive()`.

**MessageQueue** (`messageQueue.ts`) — fila com prioridade e retry.

**GroupOperationGuard** (v4.0) — add 3/10 min, remove 5/10 min, create 2/10 min,
invite 10/10 min. `classifyGroupOpError` (REACHOUT_RESTRICTED, RATE_OVERLIMIT,
PRIVACY_BLOCK…).

**MessageTypeRegistry** (v4.8) — tipos de mensagem com prioridade, pool de rate
limit e proveniência obrigatória (ex.: `user_action_id`). Só avisa, nunca estrangula.

### 3.3 Grafo de contatos e reputação

**ContactGraphWarmer** (`contactGraph.ts`, opt-in) — handshake 1:1 antes de envio em
massa/grupo, espera de 1 h após handshake, lurk de 12 h em grupo novo, máx. 5
estranhos/dia. Multiplicadores de delay (v4.4): estranho 2,5×, handshake enviado 1,8×,
handshake completo 1,3×, conhecido 1×.

**ReplyRatioGuard** (`replyRatio.ts`, opt-in) — bloqueia contato com taxa de resposta
< 10 % após 5 envios; cooldown 24 h; pode sugerir auto-resposta.

**TopologyThrottler** (v4.9) — limita expansão do grafo: 5 contatos novos/h, 20/dia,
precisa 30 % de resposta para liberar mais frios, máx. 10 do mesmo grupo, 8 do mesmo
prefixo. Score por contato: primeiro contato +40, sem resposta +20, sem grupo em comum
+15, contato recente −20, já respondeu −30; ≥ 40 → atrasar, ≥ 75 → abortar.

**ReputationVoucher** (v4.10) — usa contas antigas (6+ meses) para "avalizar" números
novos com conversas planejadas; até 5 avais/semana; crédito de 1–3 dias de aquecimento.

**JidCircuitBreaker** — disjuntor por destinatário (fechado → aberto após N falhas →
meio-aberto com 1 envio de prova).

### 3.4 Timelock e recuperação

**TimelockGuard** (`timelockGuard.ts`) — no 463 bloqueia **só contatos novos** (chats
conhecidos e grupos continuam), libera sozinho no fim + 10 s (`resumeBufferMs`).
`registerKnownChat(s)`, `lift()`, `reset()`.

**BanRecoveryOrchestrator** (v4.2) — planos por evento:

| Evento | Pausa | Retoma em | Rampa/semana | Recuperação estimada |
|---|---|---|---|---|
| `timelock` | 24 h | 10 % | +15 % | 14 dias |
| `rate_overlimit` | 4 h | 25 % | +25 % | 7 dias |
| `soft_ban` | 48 h | 5 % | +10 % | 21 dias |
| `hard_ban` | — | 0 (morto) | — | trocar número |

`shouldReplaceNumber` = hard ban ou 3+ bans em 30 dias. Acionado automaticamente pelo
HealthMonitor em critical quando via `AntiBan`/`wrapSocket`.

**MessageRecovery** — recupera mensagens perdidas após reconexão 408 (Baileys #2491).
**CredsSnapshot** — snapshot atômico de credenciais antes de reconectar (mata o loop de
corrupção do código 500/499). **deafSession** (wrapOptions) — detecta socket "surdo"
(keepalive ok mas sem mensagens há N min).

### 3.5 Humanização

**PresenceChoreographer** — digitação WPM (45 ± 15), think-pauses (8 % a cada 10
caracteres, 0,8–3,5 s), `computeTypingPlan(len)` / `executeTypingPlan(sock, jid, plan)`
(aceita AbortSignal). **Circadiano** (v3.6): perfis `default` (ativo 09–22 h, lento
22–02 h, zona morta 02–06 h 4–6× mais lento, rampa 06–09 h), `nightOwl` (+3 h),
`earlyBird` (−2 h), `always_on`. Transições suaves (cosseno).
`getCircadianMultiplier(date, profile, tz)`. Também distração (5 %, 5–20 min) e
offline (3 %, 5–15 min).

**LegitimacySignalInjector** (v4.1) — `shouldInjectTypo(text)`: texto > 10 caracteres,
sem URL, palavra ≥ 3 letras (não menção/número); correção em 500–2000 ms, `*palavra`
ou texto inteiro se < 30 caracteres. Defaults: typo 2,5 %, read gaps 15 % (5–60 min),
pausas de digitação 40 % em textos > 50 caracteres (1,5–6 s).

**readReceiptVariance** — `delayMs()` gaussiano: média 1500, desvio 800, 200–8000 ms,
pula backlog > 60 s.

**HumanEntropyService** (v4.7) — a cada 2–6 h: digitando 3–8 s (30 %), leitura atrasada
10–60 min (20 %), toggle de presença 30–120 s (15 %). Até 30 contatos recentes, só quem
escreveu primeiro. Feito para o WaSP (`createHumanEntropyService(wasp, sessionId, cfg)`);
`getStats()`.

**Stealth Connect** (v3.8.1) — `getStealthSocketConfig()` (tupla aleatória de
`STEALTH_BROWSER_POOL` + `markOnlineOnConnect:false`) e
`rampPresenceAfterConnect(sock, { minDelayMs, maxDelayMs, targetState, signal })`,
que rejeita com `AbortError` se abortado.

**Fingerprint** — `generateFingerprint({ seed, deviceModelPool, osVersionPool, appVersionPool, randomize* })`
(PRNG mulberry32, determinístico com seed), `applyFingerprint(cfg, fp)`.
`generateSessionFingerprint` / `createStealthFingerprint` (v3.x) vão além: jitter de
envio/digitação/retry, metadados de áudio, idle/keepalive, bateria, versão de protocolo.

**ContentVariator** — caracteres de largura zero, pontuação, sinônimos.

### 3.6 LID ↔ PN

**LidResolver** (LRU 10k, persistência plugável), **JidCanonicalizer**
(`canonical: 'pn'|'lid'`, `canonicalizeTarget`, `onIncomingEvent`),
**LidFirstResolver** (lê mapeamentos do diretório de auth do Baileys). Mitigação
de middleware para Bad MAC / No Session; a correção de raiz é no Baileys (PR #2372).

### 3.7 Infra, estado e frota

- **ProxyRotator** (v3.5): round-robin, random, LRU, weighted; failover, cooldown,
  ressurreição, rotação agendada; SOCKS5/5H/HTTP/HTTPS (peer deps opcionais).
- **Persistência:** `persist: './antiban-state.json'` (um escritor por arquivo),
  `FileStateAdapter`, `exportState()/importState()` (v4.8, CRDT-safe para Redis).
- **FleetEventStore:** sinais de ban/aviso/recuperação compartilhados entre instâncias
  (backend MySQL ou memória).
- **CLI:** `npx baileys-antiban status|warmup --simulate 7|reset|patch|unpatch`.
  `patch` injeta `wrapSocket` dentro do Baileys instalado (para frameworks que não
  expõem o socket), idempotente, com `.antiban-backup`; config via `ANTIBAN_PRESET`,
  `ANTIBAN_MIN_DELAY`, `ANTIBAN_MAX_DELAY`, `ANTIBAN_TYPING`.

## 4. Documentos temáticos da lib (resumo)

- **`keepalive.md`** — keepalive TCP ≠ keepalive de sessão. Reconectar com estado de
  sessão velho **causa** os logouts que se quer evitar (#2110 reconecta → logout 5–30 s
  depois; #2337 timeout silencioso em 12–24 h; loop 499 + `creds.json` corrompido).
  Solução: `reconnectThrottle` (debounce, cooldown, recusa reconectar sessão ruim) +
  `sessionStability`; para o nível TCP, a lib irmã `baileys-keep-alive`.
- **`lid-migration.md`** — migração para Linked Identity e as estratégias PN/LID.
- **`session-fingerprinting.md`** — o fingerprint de sessão completo (v3.x).

## 5. Boas práticas oficiais da lib

1. Sempre aquecer números novos. 2. Número real (VoIP é banido mais rápido).
3. Não enviar mensagens idênticas. 4. Respeitar o health monitor — quando mandar
parar, PARE. 5. Persistir o estado de aquecimento. 6. Monitorar `getStats()`.
7. Ter número reserva. 8. Respeitar os Termos do WhatsApp.

> "Esta biblioteca reduz o risco, mas não garante a prevenção de banimentos."
