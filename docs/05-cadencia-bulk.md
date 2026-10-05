# 05 — Cadência e fila do bulk (campanhas em massa)

Campanha em massa é o caminho de maior risco. O antiban atua no **ritmo** (quando
enviar), nos **gates** (se pode enviar agora) e na **contabilidade** (não queimar
contato por culpa do antiban ou da rede).

## 1. Como o bulk roda

- Cron `bulk_messaging()` no `waziper.js` (a cada poucos segundos), processa campanhas
  `sp_whatsapp_schedules.status = 1` com `time_post <= now`, **1 mensagem por campanha
  por tique**.
- Rotação de contas: `next_account` incrementa a cada envio (round-robin entre as
  instâncias da campanha).
- `schedule_time`: whitelist de horas (JSON `0..23`) com jitter de até 10 min.
- Próximo contato vem da fila `sp_whatsapp_schedule_recipients` (`bulk_queue.js`),
  `SELECT` indexado em `(schedule_id, status=0)`.

## 2. Gates antes de enviar (em ordem, no `bulk_messaging`)

| # | Condição | Ação | Queima contato? |
|---|---|---|---|
| 1 | Conta não existe / de outro time | `next_account+1, run:0` | não |
| 2 | Baileys sem sessão em memória | `next_account+1, run:0` | não |
| 3 | WebSocket `CLOSING`/`CLOSED` (readyState 2/3) | `next_account+1, run:0` | não |
| 4 | `Antiban.isTimelockBlocked(id)` | `break` | não |
| 5 | `Antiban.isHealthPaused(id)` | `next_account+1, run:0` | não |
| 6 | `bulk_settling(id)` (conectou há < `bulk_settle_seconds`) | `next_account+1, run:0` | não |
| 7 | → `auto_send()` (gates próprios, ver [01 §3.1](01-visao-geral-arquitetura.md)) | | |

## 3. Piso de intervalo entre mensagens

Intervalos de 1–5 s são o padrão mais óbvio de robô. Desde 2026-09-24:

- **PHP** (`Common_helper.php`): `bulk_delay_floor()` lê `bulk_min_delay_floor` (8 s)
  e `bulk_min_delay_gap` (4 s). `validate_bulk_delay($min,$max)` rejeita no `save()`
  de `Whatsapp_bulk` e `Whatsapp_history` se `min < piso` ou `max < min + gap`.
  As views já começam o select no piso.
- **Node** (`WAZIPER.bulk_delay(item)`): aplica o mesmo piso nas campanhas antigas
  (cache 60 s): `min = max(item.min_delay, floor)`, `max = max(item.max_delay, min + gap)`,
  `delay = floor(random × max) + min` (fórmula legada mantida).

## 4. Estabilização pós-conexão (settle)

`connectedAt[id]` é gravado no `connection 'open'`. Enquanto
`now − connectedAt < bulk_settle_seconds` (default **120 s**), a conta é pulada.
Enviar logo após o `open` — sobretudo numa conta que cai e volta em loop — é padrão
de robô. Independe do stealth connect (que só atrasa o `available`).

## 5. Falha transitória não queima contato

`WAZIPER.is_transient_send_error(err)` → `true` para:
- número cru 1000–4999 (código de close do WebSocket, ex.: 1006);
- `statusCode` 428 (connectionClosed) ou 408 (connectionLost/timedOut);
- mensagem com `Connection Closed|Lost|Terminated|Timed Out|WebSocket was closed`.

Nesse caso `process_send_message` devolve `{ stats:false, transient:true }`:
não grava no `result`, **não** chama `recordMessageFailed`, e o `bulk_messaging`
empurra `time_post` em **30–60 s** (antes: retry a cada 5 s martelando a conta)
e passa para a próxima conta.

Falha **real** → `Antiban.recordMessageFailed` + `stats:true` + contato marcado como falho.

## 6. Contabilidade da campanha

| Origem do "não enviou" | `stats` | Efeito |
|---|---|---|
| Timelock 463 | `false` | contato fica pendente |
| Health pause | `false` | contato fica pendente |
| Cota mensal do plano | `false` | — |
| Falha transitória | `false` + `transient` | backoff 30–60 s |
| Número marcado inválido (`is_valid = 2`) | `true`, status 0 | conta como falha |
| Erro real do Baileys | `true`, status 0 | falha + score do HealthMonitor |
| Sucesso | `true`, status 1 | `BulkQueue.mark(queue_id, 1, { instance_id, jid, msg_id })` |

## 7. Rastreio de entrega, leitura e resposta

Desde 2026-09-24 (`bulk_queue.js` + migration `2026_09_24_recipients_tracking.sql`):

- `sp_whatsapp_schedule_recipients` ganhou `instance_id`, `jid` (dígitos), `msg_id`,
  `ack`, `delivered_at`, `read_at`, `replied_at` (+ índices).
- `BulkQueue.onUpdates(messages.update)` atualiza `ack` (1 pendente, 2 servidor,
  3 entregue, 4 lida, 5 reproduzida) — **nunca regride**.
- `BulkQueue.onIncoming(messages.upsert notify)` marca `replied_at`. DMs `@lid` casam
  pelo `key.remoteJidAlt` (100 % das mensagens trazem). Janela de 7 dias, índices em
  memória carregados no boot por `loadTracking()`.
- PHP `bulk_engagement($group, $ids, $since)` agrega por `schedule_id` ou `instance_id`:
  `delivered_pct`, `read_pct`, `replied_pct`, `stuck` (ack ≤ 2 há mais de 24 h).
- Exibido na lista de campanhas (coluna "Engajamento") e na Central Antiban
  ("Entrega / respostas (7d)", verde ≥ 85 %, amarelo ≥ 60 %, vermelho < 60 %).

Baseline medido: taxa de resposta real ~27 %. **Entrega < 60 % é o sinal mais precoce
de soft-ban** (referência da lib) — hoje é só exibido, ainda não alimenta o score
(ver [11](11-historico-roadmap.md)).

Rollback da fila sem deploy: `sp_options.bulk_queue_legacy = 1` volta ao `NOT IN` antigo.

## 8. Recomendações operacionais (fora do código)

- Chip novo: aquecer com **mensagens recebidas** (pessoas reais escrevendo primeiro)
  antes de qualquer disparo; volume baixo nas primeiras semanas.
- Primeira mensagem a um estranho: curta, sem link, sem mídia, convidando resposta.
- Spintax real (saudação, ordem, emoji) + `unique_media` em campanhas com imagem.
- Mais números com orçamento baixo > poucos números com volume alto.
- Proxy residencial BR *sticky*; nunca rotacionar fingerprint.
