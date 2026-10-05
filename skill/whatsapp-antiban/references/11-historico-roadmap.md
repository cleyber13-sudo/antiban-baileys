# 11 — Histórico e roadmap

## 1. Linha do tempo

| Data | Mudança | Motivação |
|---|---|---|
| até 2026-08 | Lib `baileys-antiban` instalada; só HealthMonitor (pontuação), JidCanonicalizer (quebrado) e PresenceChoreographer em uso | — |
| 2026-08-20 | Presença "Digitando" como default em campanha nova | campanhas sem presença |
| 2026-08-28 | **Pausa real por 463** + 401/403: `timelockEpisodes`, `pauseCampaignsForInstance`, `resumeAntibanPauses` (cron 30 s), boot sweep, painel "Pausas ativas", +7 colunas no alerta | INSTANCIA_C deslogado no meio de campanha sem pausa |
| 2026-08-28 | Dedup de alerta `risk` (1 h) e retenção de 7 dias no painel | painel poluído por restart do pm2 a cada 20 min |
| 2026-08-31 | **forced_resume** + reset do HealthMonitor + polling do painel + backoff do `live_back` pós-403 | "Retomar agora" ficava preso em "liberando…" |
| 2026-09-01 | Botão **Limpar alertas** (`archived`, protege pausa real) | |
| 2026-09-02 | **Fases A–G** da humanização: fingerprint por instância, typos, read receipts, HumanEntropyService, Stealth Connect, fix do `getCanonicalizer`, **Central Antiban** (config via `sp_options`, sem restart), `/antiban_overview` | plano de evolução |
| 2026-09-02 | Proxy: `fetchAgent` (mídia pelo proxy) + máscara de senha no log | mídia vazava IP |
| 2026-09-03 | Plano anti-403 (só plano) | INSTANCIA_B tomou 403 rodando bulk como número novo |
| 2026-09-03 | Fix do status "Conectado" fantasma pós-401/403 | |
| 2026-09-10 | **Retomada automática virou opt-in** (`antiban_auto_resume=0`) | loop reconecta → retoma → 403 em INSTANCIA_A |
| 2026-09-24 | **A1** pausa por risco não queima contato · **A2** score ignora quedas de infra · **A3** piso de delay 8 s + gap 4 s | 22 contatos queimados em 23/09; 428 dominava o score; delays de 1–5 s |
| 2026-09-24 | Fila `sp_whatsapp_schedule_recipients`, **rastreio de entrega/leitura/resposta**, settle pós-conexão (120 s), backoff transitório 30–60 s, falha transitória não queima contato | sistema cego para entrega; @lid impedia casar respostas |
| 2026-10-03 | **Imagem única por contato** (`unique_media`) | mesma imagem para milhares = mesmo hash |
| 2026-10-03 | Presence Delay manual (plano WPM reescalado para `presenceTime`) | tempo definido pelo operador |

## 2. Roadmap (pendente)

Consolidado de `PLANO_antiban_evolucao_comportamento_humano.md` (2026-09-02) e
`PLANO_estrategias_anti_403.md` (2026-09-03).

### Curto prazo (alto impacto, baixo risco)
1. **Taxa de entrega → score / circuit breaker por campanha.** Os dados já existem
   (`ack` em `sp_whatsapp_schedule_recipients`). Regras sugeridas: entrega < 70 % na
   janela → alerta `medium`; < 55 % → pausa preventiva; primeiras ~20 mensagens da
   campanha com entrega ruim → aborta a campanha.
2. **Warmup / teto diário e por hora por idade da conta** (contas < 14 dias primeiro):

   | Idade | Teto/dia | Teto/hora |
   |---|---|---|
   | Dia 1–2 | 20 | 5 |
   | Dia 3–7 | 20 → 80 | 10 |
   | Semana 2 | 200 | 25 |
   | Semana 3–4 | 500 | 50 |

   Gate: orçamento esgotado → pula a conta sem queimar contato.
3. **Intervalo gaussiano + micro-pausas** (a cada 15–40 mensagens, pausa de 5–20 min)
   + modulação circadiana do gap.
4. **Lista de supressão** de não-respondentes (0 respostas em ≥ 3 campanhas, inválidos, opt-out).
5. **Documentos operacionais**: aquecimento por inbound, aquisição de chip, cooldown pós-403.

### Médio prazo
6. **Retomada rampada** (BanRecoveryOrchestrator): 463 → 10 % +15 %/semana;
   401/403 → 5 % +10 %/semana; `forced_resume` também rampado.
7. **Gate pré-envio / preflight** no painel de bulk (`/antiban_overview` com
   `can_send`, `blockers`, `connection_age_days`, `delivery_ratio_1h`).
8. **Soft signals** (`Antiban.recordSoftSignal`): 440, `CB:stream:error`, rajada de
   chamadas recebidas, ✓ presa, notificações pendentes que não chegam.
9. **Probe de metadados** (cron): `fetchStatus`/`onWhatsApp` falhando antes do 403.
10. Orçamento por IP/proxy (InstanceCoordinator).
11. Sequenciar audiência por risco (respondeu antes > contato salvo > validado > frio).

### Longo prazo
12. **Número-sentinela** (canary) antes da frota.
13. Governador de ritmo central entre campanhas.
14. `wrapSocket()` completo (testar com o fork `@itsukichan/baileys` em staging).
15. Escada de alertas (webhook + painel + e-mail/Telegram).

## 3. Limite estrutural

Baileys é API não-oficial: as medidas **adiam** 463/401/403. Para volume alto, o
caminho sem gato e rato é a **WhatsApp Cloud API**. Isso deve estar explícito no
planejamento do produto e na comunicação com clientes.
