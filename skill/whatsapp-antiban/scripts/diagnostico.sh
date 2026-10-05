#!/usr/bin/env bash
# Diagnóstico somente-leitura do sistema antiban (Contatizs / wa_serever).
#
# Uso:
#   diagnostico.sh                 # visão geral da frota
#   diagnostico.sh <instance_id>   # foco numa instância (token de sp_accounts)
#
# Variáveis opcionais:
#   CONTATIZS_ROOT  raiz do projeto (default <RAIZ_PROJETO>)
#   PM2_LOG_DIR     pasta de logs do pm2 (default <PM2_LOG_DIR>)
#   PM2_APP         nome do processo pm2 do wa_serever (default <PM2_APP>)
#   LOG_DAYS        quantos arquivos rotacionados por tipo varrer (default 3)
#
# Não altera nada: só SELECT no MySQL, GET no Redis e grep no log.
# As credenciais do banco são lidas do .env do projeto e passadas ao mysql por
# arquivo temporário (não aparecem em `ps`).

set -euo pipefail

ROOT="${CONTATIZS_ROOT:-<RAIZ_PROJETO>}"
LOG_DIR="${PM2_LOG_DIR:-<PM2_LOG_DIR>}"
PM2_APP="${PM2_APP:-<PM2_APP>}"

# Marcadores não preenchidos = rodando direto do repositório, sem instalar.
if [[ "$ROOT$LOG_DIR$PM2_APP" == *"<"* ]]; then
  echo "Instale a skill com scripts/sync-skill.sh --projeto (ou exporte CONTATIZS_ROOT, PM2_LOG_DIR e PM2_APP)." >&2
  exit 1
fi
LOG_DAYS="${LOG_DAYS:-3}"
ID="${1:-}"

if [[ -n "$ID" && ! "$ID" =~ ^[A-Za-z0-9_-]{4,64}$ ]]; then
  echo "instance_id inválido: $ID" >&2
  exit 1
fi

envval() {
  grep -E "^\s*$1\s*=" "$ROOT/.env" | head -1 | sed -E "s/^[^=]*=\s*//; s/^['\"]//; s/['\"]\s*$//"
}

DB_HOST="$(envval database.default.hostname)"
DB_NAME="$(envval database.default.database)"
DB_USER="$(envval database.default.username)"
DB_PASS="$(envval database.default.password)"

CNF="$(mktemp)"
trap 'rm -f "$CNF"' EXIT
chmod 600 "$CNF"
printf '[client]\nhost=%s\nuser=%s\npassword=%s\n' "${DB_HOST:-localhost}" "$DB_USER" "$DB_PASS" > "$CNF"

q() { mysql --defaults-extra-file="$CNF" "$DB_NAME" -t -e "$1"; }

WHERE_ID=""
[[ -n "$ID" ]] && WHERE_ID="AND instance_id = '$ID'"

echo "=== Config antiban (sp_options) ==="
q "SELECT name, value FROM sp_options WHERE name LIKE 'antiban\\_%' OR name LIKE 'bulk\\_%' ORDER BY name;"

echo; echo "=== Pausas pendentes ==="
q "SELECT id, instance_id, type, recurrence rec, FROM_UNIXTIME(created) criado,
          FROM_UNIXTIME(resume_at) retoma, manual_hold hold, auto_resume_disabled so_manual,
          forced_resume forcado, LEFT(active_campaigns, 80) campanhas
   FROM sp_whatsapp_antiban_alerts
   WHERE type IN ('timelock','loggedout','forbidden') AND resumed_at IS NULL $WHERE_ID
   ORDER BY id DESC LIMIT 30;"

echo; echo "=== Eventos 463/401/403 e alertas de risco (7 dias) ==="
q "SELECT instance_id, type, risk, COUNT(*) n, FROM_UNIXTIME(MAX(created)) ultimo
   FROM sp_whatsapp_antiban_alerts
   WHERE created > UNIX_TIMESTAMP() - 7*86400 $WHERE_ID
   GROUP BY instance_id, type, risk ORDER BY ultimo DESC LIMIT 40;"

echo; echo "=== Entrega / leitura / resposta do bulk (7 dias) ==="
q "SELECT instance_id, COUNT(*) enviados,
          ROUND(100*SUM(ack>=3)/COUNT(*),1) entregue_pct,
          ROUND(100*SUM(ack>=4)/COUNT(*),1) lida_pct,
          ROUND(100*SUM(replied_at IS NOT NULL)/COUNT(*),1) resposta_pct,
          SUM(ack<=2 AND sent_at < UNIX_TIMESTAMP()-86400) presas
   FROM sp_whatsapp_schedule_recipients
   WHERE status=1 AND msg_id IS NOT NULL AND sent_at > UNIX_TIMESTAMP()-7*86400 $WHERE_ID
   GROUP BY instance_id ORDER BY enviados DESC LIMIT 40;" 2>/dev/null \
  || echo "(colunas de rastreio ausentes — migration 2026_09_24_recipients_tracking não aplicada?)"

if [[ -n "$ID" ]]; then
  echo; echo "=== Conta ==="
  q "SELECT id, name, pid, team_id, status, login_type, FROM_UNIXTIME(changed) changed
     FROM sp_accounts WHERE token = '$ID';"

  echo; echo "=== Campanhas que usam a conta ==="
  q "SELECT s.id, s.name, s.status, s.min_delay, s.max_delay, s.presenceType, s.presenceTime,
            s.unique_media, FROM_UNIXTIME(s.changed) changed
     FROM sp_whatsapp_schedules s JOIN sp_accounts a ON a.token = '$ID'
     WHERE s.accounts != '' AND JSON_VALID(s.accounts) AND JSON_CONTAINS(s.accounts, JSON_QUOTE(CAST(a.id AS CHAR)))
     ORDER BY s.id DESC LIMIT 15;" 2>/dev/null || true

  echo; echo "=== Redis ==="
  for k in "antiban:health:$ID" "antiban:timelock:$ID"; do
    echo "--- $k (ttl $(redis-cli ttl "$k" 2>/dev/null || echo '?')s)"
    v="$(redis-cli get "$k" 2>/dev/null || true)"
    if [[ -n "$v" ]] && command -v jq >/dev/null; then
      echo "$v" | jq -c '{paused, lastRisk, lastEventWasSevere, eventos: ((.events // []) | group_by(.type) | map({(.[0].type): length}) | add)} // .' 2>/dev/null || echo "$v"
    else
      echo "${v:-(vazio)}"
    fi
  done
fi

echo; echo "=== Últimas linhas do antiban nos logs do pm2 ($LOG_DIR) ==="
# console.warn/error -> <PM2_APP>-error*.log ; console.log -> <PM2_APP>-out*.log
# (rotação diária pelo pm2-logrotate). Linhas começam com a data (log_date_format).
FILES=()
for kind in error out; do
  while IFS= read -r f; do FILES+=("$f"); done < <(ls -t "$LOG_DIR"/"$PM2_APP"-"$kind"*.log 2>/dev/null | head -n "$((LOG_DAYS + 1))")
done
if (( ${#FILES[@]} )); then
  PATTERN='\[(ANTIBAN|live_back|bulk|status|UNIQUE_MEDIA)\]'
  if [[ -n "$ID" ]]; then
    grep -hE "$PATTERN" "${FILES[@]}" | grep -F "$ID" | sort | tail -40 || true
  else
    grep -hE '\[ANTIBAN\]' "${FILES[@]}" | sort | tail -40 || true
  fi
else
  echo "(nenhum log encontrado em $LOG_DIR)"
fi
