# 10 — Runbook operacional

## 1. Onde olhar

| O quê | Onde |
|---|---|
| Logs do Node | `<PM2_LOG_DIR>/<PM2_APP>-error.log` (`console.warn/error` → quase todo `[ANTIBAN]`) e `<PM2_APP>-out.log` (`console.log`); processo pm2 `<PM2_APP>`, horário BRT, rotação diária (`contatizs-*__AAAA-MM-DD_*.log`) |
| Crashes engolidos | `wa_serever/logs/crash.log` (`uncaughtException`/`unhandledRejection`) |
| Estado de risco ao vivo | `GET /health_status?access_token=…&instance_id=…` ou Central Antiban |
| Panorama da frota | `GET /antiban_overview?access_token=…&all=1` |
| Score persistido | Redis `antiban:health:<id>` |
| Pausas e alertas | `sp_whatsapp_antiban_alerts` |

### Tags de log

| Tag | Significado |
|---|---|
| `[ANTIBAN] <id> risk -> high (score N): …` | mudança de nível do HealthMonitor |
| `[ANTIBAN] <id> pausa real (timelock|loggedout|forbidden) — N campanha(s), cooldown Xs, reincidência R` | pausa nova |
| `[ANTIBAN] <id> pausa fundida em #id (…)` | evento somado a pausa pendente |
| `[ANTIBAN] envio bloqueado (timelock 463) …` / `… risco de ban alto` | gate do `auto_send` |
| `[ANTIBAN] <id> retomada forçada|automática (tipo) — N campanha(s)` | retomada |
| `[ANTIBAN] <id> alerta X fechado — campanhas já não estão pausadas` | órfão reconciliado |
| `[ANTIBAN] N pausa(s) de timelock reidratada(s) do banco` | boot |
| `[ANTIBAN] HumanEntropyService iniciado|parado (flag off)` | entropy |
| `[ANTIBAN] Redis indisponível…` | persistência caiu (segue em memória) |
| `[live_back] <id> em backoff pós-401/403 (Ns)` | não recria socket |
| `[bulk] falha transitória de conexão …` | contato preservado, backoff 30–60 s |
| `[UNIQUE_MEDIA] falhou, enviando imagem original` | fallback da imagem única |
| `[status] <id> marcada como desconectada no banco (close 401|403)` | badge do painel corrigido |
| `[lid_resolver] …` | resolvedor @lid |

```bash
# atual + rotacionados, error e out, em ordem cronológica
grep -hE "\[ANTIBAN\]" <PM2_LOG_DIR>/contatizs-{error,out}*.log | sort | tail -50
grep -hE "\[ANTIBAN\].*(pausa real|retomada)" <PM2_LOG_DIR>/contatizs-{error,out}*.log | sort | tail
```

Atalho: `skill/whatsapp-antiban/scripts/diagnostico.sh [instance_id]` (somente leitura)
junta config, pausas, eventos, engajamento, Redis e log.

## 2. SQL úteis

> **Fuso:** o servidor e o pm2 estão em BRT (`America/Sao_Paulo`) desde 2026-09-03,
> mas o MySQL não foi alterado — `FROM_UNIXTIME()` sai no fuso do MySQL (≈ +5 h em
> relação ao log). Compare sempre pelo epoch ou converta com `CONVERT_TZ`.

```sql
-- Pausas pendentes
SELECT id, instance_id, type, recurrence, FROM_UNIXTIME(created) criado,
       FROM_UNIXTIME(resume_at) retoma, manual_hold, auto_resume_disabled, forced_resume,
       active_campaigns
FROM sp_whatsapp_antiban_alerts
WHERE type IN ('timelock','loggedout','forbidden') AND resumed_at IS NULL
ORDER BY id DESC;

-- Histórico de 401/403/463 por instância (7 dias)
SELECT instance_id, type, COUNT(*) n, FROM_UNIXTIME(MAX(created)) ultimo
FROM sp_whatsapp_antiban_alerts
WHERE created > UNIX_TIMESTAMP() - 7*86400 AND type <> 'risk'
GROUP BY instance_id, type ORDER BY n DESC;

-- Config antiban em vigor
SELECT name, value FROM sp_options
WHERE name LIKE 'antiban\_%' OR name LIKE 'bulk\_%' ORDER BY name;

-- Campanhas paradas pelo antiban (status 0 e changed igual ao gravado)
SELECT s.id, s.name, s.status, s.changed FROM sp_whatsapp_schedules s
WHERE s.status = 0 AND s.id IN (/* ids de active_campaigns */);

-- Entrega/leitura/resposta por instância (7 dias)
SELECT instance_id, COUNT(*) enviados,
  ROUND(100*SUM(ack>=3)/COUNT(*),1) entregue_pct,
  ROUND(100*SUM(ack>=4)/COUNT(*),1) lida_pct,
  ROUND(100*SUM(replied_at IS NOT NULL)/COUNT(*),1) resposta_pct,
  SUM(ack<=2 AND sent_at < UNIX_TIMESTAMP()-86400) presas
FROM sp_whatsapp_schedule_recipients
WHERE status=1 AND msg_id IS NOT NULL AND sent_at > UNIX_TIMESTAMP()-7*86400
GROUP BY instance_id;
```

## 3. Procedimentos

### 3.1 "A campanha parou sozinha"
1. Alertas Antiban do time → há card em "Pausas ativas"? Veja o tipo.
2. `timelock` (463): o WhatsApp limitou contato com números novos. Esperar o cooldown,
   **reduzir volume**, priorizar conversas existentes, depois "Retomar agora".
3. `loggedout` (401) / `forbidden` (403): conferir se a instância reconectou
   (badge, `/health_status`). Se não → re-parear (QR/pair code). Só então "Retomar agora".
4. Recomendação diz "voltou a bloquear logo após a retomada" → **não insistir**:
   re-parear ou trocar o número.
5. Instância morta e não vai voltar → "Encerrar sem retomar" (campanhas ficam pausadas).

### 3.2 "Cliquei Retomar agora e nada aconteceu"
- O cron exige **socket vivo** (`sessions[id]`). Sem conexão, o card fica em
  "liberando…" até a instância reconectar.
- Campanha mexida à mão depois da pausa (`changed` diferente) **não** é religada — é
  proposital. Religar pela tela de campanhas.
- Confirmar `forced_resume=1` no alerta e procurar `[ANTIBAN] … retomada forçada` no log.

### 3.3 "Risco alto mas nada de errado"
- Ver `reasons`. "N disconnects in last hour" com códigos de infra não deveria mais
  acontecer (filtro desde 2026-09-24). Se aparecer, conferir o código real do close.
- O score decai 5 pts/min (2 pts/min após 401/403). Não há botão só para zerar o
  score: o "Retomar agora" de um alerta de pausa da instância faz `forceHealthResume`
  (se ela estiver conectada e em health pause). Fora isso, aguardar o decaimento.

### 3.4 Ligar humanização para uma instância
Central Antiban → tabela "Por instância" → select da função → "Ligado". Vale em ~1 min.
Stealth e fingerprint valem na próxima reconexão. Para todas: allowlist `*`.

### 3.5 Mudar cooldowns / retomada automática
Central Antiban (toggle de retomada) ou `UPDATE sp_options SET value=… WHERE name=…`
para as chaves `antiban_timelock_*`, `antiban_disconnect_cooldown`,
`antiban_quick_reblock_window`. TTL 5 min, sem restart.

### 3.6 Depois de alterar código do wa_serever
```bash
cd <RAIZ_PROJETO>/wa_serever
node -e "require('./waziper/antiban.js')" && echo OK   # sanity de sintaxe
pm2 restart <PM2_APP> --update-env                       # restart (derruba sockets!)
pm2 logs <PM2_APP> --lines 100
```
Restart derruba todas as conexões: evitar durante campanhas. Há um restart diário agendado de madrugada.
Pausas 463 sobrevivem (reidratadas do banco); o score sobrevive (Redis, 6 h).

### 3.7 Chip novo (procedimento recomendado)
1. SIM físico, usado manualmente por semanas antes de vincular.
2. Pessoas reais mandam mensagem **para** o número antes do primeiro disparo.
3. Primeiros dias: dezenas de envios/dia, delays ≥ piso, Digitando ligado,
   sem link, primeira mensagem curta que convida resposta.
4. Ligar read receipts e entropy para a instância.
5. Na 3ª reincidência de 403: trocar o chip.

## 4. Checklist ao mexer no antiban (código)

- [ ] Nada do antiban pode lançar exceção para o fluxo de envio/recebimento (try/catch).
- [ ] Bloqueio do antiban → `stats:false` (não queimar contato).
- [ ] Pausa grava `changed`; retomada confere `changed`.
- [ ] Config nova: chave `antiban_*` em `sp_options` + default no código + `GLOBAL_KEYS`
      do controller se for exposta no painel + entrada em [07](07-banco-config-redis.md).
- [ ] PHP: usar constantes `TB_*`, filtrar por `team_id`, POST com token CSRF.
- [ ] SQL de migração não-destrutivo, sem `COLLATE` explícito em `instance_id`.
- [ ] Traduções em `writable/lang/pt-br.json` e `es-mx.json`.
- [ ] Node: lembrar que precisa restart do pm2 para valer.
