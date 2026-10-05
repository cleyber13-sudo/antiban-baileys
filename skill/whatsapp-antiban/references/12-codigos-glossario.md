# 12 — Códigos e glossário

## 1. Códigos de desconexão (`lastDisconnect.error.output.statusCode`)

| Código | Baileys (`DisconnectReason`) | Tratamento no projeto | Pontua no score? |
|---|---|---|---|
| **401** | `loggedOut` | pausa real `loggedout` + status 0 no banco + apaga sessão e recria + backoff 10 min | sim (+60) |
| **403** | `forbidden` | pausa real `forbidden` + status 0 + backoff 10 min | sim (+40 cada) |
| 408 | `connectionLost` / `timedOut` | reconecta | **não** (infra) |
| 411 | `multideviceMismatch` | reconecta | sim (disconnect) |
| 428 | `connectionClosed` | reconecta | **não** (infra) |
| 440 | `connectionReplaced` | reconecta | sim (disconnect) |
| 500 | `badSession` | reconecta | sim (disconnect) |
| 503 | `unavailableService` | reconecta | **não** (infra) |
| 515 | `restartRequired` (normal após parear) | reconecta | **não** (infra) |
| 1000/1001/1005/1006 | close do WebSocket | reconecta | **não** (infra) |
| `unknown`/`undefined` | sem código | reconecta | **não** |
| 0 | — | trata como logout (limpa sessão) | sim |

## 2. Códigos de erro de envio / stub

| Código | Significado | Tratamento |
|---|---|---|
| **463** | *reachout timelock*: WhatsApp limitou o contato com números novos | `messages.update` stub → pausa real `timelock` |
| 429 | rate limit | disjuntor do LidResolver |
| 428/408 em `sendMessage` | conexão caiu no envio | falha transitória (não queima contato) |

## 3. `ack` (WAMessageStatus)

| Valor | Estado |
|---|---|
| 0 | erro |
| 1 | pendente (relógio) |
| 2 | servidor (✓) |
| 3 | entregue (✓✓) |
| 4 | lida (✓✓ azul) |
| 5 | reproduzida (áudio/vídeo) |

## 4. Níveis de risco (HealthMonitor, código da lib)

| Nível | Score | Recomendação da lib | Efeito no projeto |
|---|---|---|---|
| low | 0–14 | operar normal | — |
| medium | 15–39 | reduzir 50 % | só aparece no painel |
| high | 40–79 | reduzir 80 %, pausar 1–2 h | **health pause** (envios saem com `stats:false`) + alerta `risk` + webhook |
| critical | 80–100 | parar tudo 24–48 h | idem |

## 5. Glossário

| Termo | Definição |
|---|---|
| **Instância** | uma conta WhatsApp conectada; `instance_id` = `sp_accounts.token` |
| **Baileys** | biblioteca não-oficial que fala o protocolo do WhatsApp Web (aqui o fork `@itsukichan/baileys`) |
| **API oficial** | WhatsApp Cloud API (`login_type = 1`), fora do escopo do antiban |
| **Bulk** | campanha de envio em massa (`sp_whatsapp_schedules`) |
| **Pausa real** | campanha colocada em `status=0` pelo antiban, com alerta e cooldown |
| **Health pause** | bloqueio de envio por score alto (não muda status da campanha) |
| **Cooldown** | tempo mínimo de pausa antes de poder retomar |
| **Reincidência** (`recurrence`) | quantas vezes o evento se repetiu; dobra o cooldown do 463 |
| **Forced resume** | retomada manual ("Retomar agora") que ignora travas de risco |
| **Manual hold** | "Manter pausado": impede retomada automática |
| **Órfão** | alerta de pausa cujas campanhas já foram mexidas por fora |
| **Queimar contato** | marcar contato como enviado/falho sem ter enviado de fato |
| **Settle** | janela pós-conexão sem disparos (`bulk_settle_seconds`) |
| **Stealth connect** | conectar sem anunciar "online" e subir a presença depois |
| **Fingerprint** | tupla `browser` `[SO, navegador, versão]` que identifica o dispositivo vinculado |
| **Entropy** | ruído de fundo humano (digitando, leitura, presença) a cada 2–6 h |
| **Typo** | erro de digitação proposital seguido de correção |
| **LID** | *Linked Identity*: JID `número@lid` que o WhatsApp usa no lugar do telefone |
| **PN** | *phone number* JID: `número@s.whatsapp.net` |
| **Bad MAC** | falha de descriptografia Signal (sessão LID/PN divergente) |
| **remoteJidAlt** | campo da key que traz o PN de uma mensagem recebida via @lid |
| **Soft-ban** | conta ainda conectada mas com entrega degradada (✓ que não vira ✓✓) |
| **Warmup** | aquecimento gradual de volume em número novo |
| **Circadiano** | variação de ritmo conforme a hora do dia |
| **WPM** | palavras por minuto do modelo de digitação |
