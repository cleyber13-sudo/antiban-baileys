# 09 — Biblioteca × projeto: o que usamos, como e o que falta

O projeto **não** usa `wrapSocket()` nem a classe `AntiBan`. Ele importa módulos
avulsos da lib dentro de `antiban.js` e mantém uma camada própria (pausa real,
retomada, painel) mais integrada ao produto. Decisão consciente (2026-09-02): não
ligar RateLimiter/warmup/bloqueio de mensagens idênticas sem antes ter governança de
volume no painel, e evitar conflito com o fork `@itsukichan/baileys`.

## 1. Matriz de adoção

| Módulo da lib | Status | Onde / como |
|---|---|---|
| HealthMonitor | ✅ usado | 1 por instância, `autoPauseAt:'high'`, filtro de códigos de infra, persistido no Redis |
| JidCanonicalizer | ✅ usado | `canonical:'pn'`, antes de todo envio e em todo upsert |
| PresenceChoreographer | ✅ usado | WPM + circadiano `America/Sao_Paulo`; plano reescalado para `presenceTime` |
| generateFingerprint | ✅ usado | tupla `browser` determinística por instância (pools próprios) |
| rampPresenceAfterConnect / AbortError | ✅ usado | stealth connect, com `markOnlineOnConnect:false` |
| LegitimacySignalInjector | ✅ parcial | só typos (+ pausas opcionais); `enableReadGaps:false` |
| readReceiptVariance | ✅ usado | leitura de DM com atraso; allowlist |
| HumanEntropyService | ✅ adaptado | EventEmitter por instância no lugar do WaSP |
| TimelockGuard | ❌ substituído | pausa real própria (pausa **todas** as campanhas da instância, não só contatos novos) |
| BanRecoveryOrchestrator | ❌ | retomada é em velocidade cheia (sem rampa 10 % → 100 %) |
| DeliveryTracker | ❌ (equivalente parcial) | `bulk_queue.js` rastreia ack/leitura/resposta e o painel mostra; **não** alimenta o score |
| RateLimiter (gaussiano/adaptativo) | ❌ | intervalo uniforme `random×max+min` com piso 8 s / gap 4 s |
| WarmUp / tetos diário-hora | ❌ | só cota mensal do plano |
| InstanceCoordinator (orçamento por IP) | ❌ | |
| ContactGraph / TopologyThrottler / ReplyRatioGuard | ❌ | |
| PostReconnectThrottle | ❌ (equivalente) | `bulk_settle_seconds` (120 s) pula a conta inteira |
| ContentVariator | ❌ (equivalente parcial) | spintax/IA no texto + `unique_media` na imagem |
| GroupOperationGuard | ❌ | |
| ProxyRotator | ❌ | proxy por instância próprio (`sp_proxies`), com `fetchAgent` |
| classifyDisconnect | ❌ (de propósito) | classificação da lib diverge do enum do Baileys |
| MessageRecovery / CredsSnapshot / deafSession | ❌ | |
| ReputationVoucher / MessageTypeRegistry / FleetEventStore | ❌ | |

## 2. Onde o projeto vai além da lib

- **Pausa real com fonte de verdade no banco**, fusão por instância, reincidência com
  backoff exponencial, anti ping-pong (re-bloqueio rápido), forced resume com reset
  do score, reconciliação de órfãos, reidratação no boot.
- **Retomada automática opt-in** (a lib retoma sozinha no TimelockGuard).
- **Contabilidade "não queimar contato"** (`stats:false`) em toda pausa e falha transitória.
- **Backoff pós-401/403 no `live_back`** (não recriar socket em rajada).
- **Painel**: Central Antiban (global + override por instância, sem restart) e Alertas
  Antiban por time, webhooks `antiban.*`, socket.io.
- **Imagem com hash único** por contato.
- **Rastreio de resposta com @lid** via `key.remoteJidAlt`.

## 3. Divergências e armadilhas da lib

1. **Score contaminado por quedas de infra.** O HealthMonitor conta todo código ≠
   401/403 como "disconnect" (≥ 3/h = +30 → `medium`; somado a falhas → `high`).
   Em produção, 428 dominava (116 em um dia) e gerava pausas falsas. O projeto
   filtra `428, 408, 515, 503, 1000, 1001, 1005, 1006, unknown, undefined`.
2. **Faixas de risco do README estão erradas**: código usa 15 / 40 / 80.
3. **`classifyDisconnect` trata 428 e 515 como fatais** — no Baileys 428 é
   `connectionClosed` e 515 é `restartRequired` (normal após parear). Não usar para
   decidir reconexão.
4. **`growthFactor` do WarmUp é aleatório** (1,5–2,2) se não for fixado.
5. **HumanEntropyService acoplado ao WaSP** — precisa do adaptador de EventEmitter.
6. **`persist` em arquivo assume um escritor só** — com várias instâncias, um arquivo
   por instância (ou Redis via `exportState`).
7. **Pacote ESM puro** na raiz; o projeto (CJS) usa o build `dist/cjs` via `require`.
8. `LegitimacySignalInjector` gera **mensagem extra real** no chat (typo + correção).

## 4. Lacunas priorizadas (do plano de evolução)

| Prioridade | Item | Por quê |
|---|---|---|
| 1 | Alimentar o score com a **taxa de entrega** (já medida em `sp_whatsapp_schedule_recipients`) + circuit breaker por campanha | ✓✓ caindo é o sinal mais precoce de soft-ban; hoje só é exibido |
| 2 | **Warmup / teto diário-hora por idade da conta** | conta nova + volume alto = padrão nº 1 de ban (casos INSTANCIA_C / INSTANCIA_B) |
| 3 | **Intervalo gaussiano + micro-pausas + modulação circadiana do gap** | distribuição uniforme é assinatura de bot |
| 4 | **Retomada rampada** (BanRecoveryOrchestrator) | hoje volta em 100 % após a pausa |
| 5 | Orçamento por IP/proxy (InstanceCoordinator) | várias contas no mesmo IP somam taxa |
| 6 | Grafo de contatos / supressão de não-respondentes / primeiro contato 2,5× | estranhos e não-respondentes geram denúncia |
| 7 | Soft signals (440, `CB:stream:error`, rajada de chamadas, ✓ preso) | precursores do 403 |
| 8 | Número-sentinela (canary) antes da frota | descobrir bloqueio antes de todas as contas baterem nele |

Detalhes em [11](11-historico-roadmap.md) e nos planos originais
(`docs/PLANO_antiban_evolucao_comportamento_humano.md`,
`docs/PLANO_estrategias_anti_403.md` no projeto).
