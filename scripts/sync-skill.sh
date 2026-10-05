#!/usr/bin/env bash
# Copia docs/ para skill/whatsapp-antiban/references/ (as referências da skill
# são os próprios docs) e, opcionalmente, instala a skill.
#
#   scripts/sync-skill.sh              # só sincroniza (repo fica com marcadores)
#   scripts/sync-skill.sh --projeto    # + instala em <RAIZ_PROJETO>/.claude/skills/
#   scripts/sync-skill.sh --global     # + instala em ~/.claude/skills/
#
# O repositório só guarda MARCADORES de infraestrutura (<RAIZ_PROJETO>,
# <PM2_APP>, <PM2_LOG_DIR>, <PORTA_WA>). Os valores reais ficam em `.local.env`
# (fora do git — ver .local.env.example) e só são aplicados na cópia instalada.
set -euo pipefail
cd "$(dirname "$0")/.."

rm -f skill/whatsapp-antiban/references/*.md
cp docs/*.md skill/whatsapp-antiban/references/
echo "references sincronizadas: $(ls skill/whatsapp-antiban/references | wc -l) arquivos"

case "${1:-}" in
  --projeto|--global) ;;
  *) exit 0 ;;
esac

if [[ ! -f .local.env ]]; then
  echo "Crie .local.env a partir de .local.env.example antes de instalar." >&2
  exit 1
fi
# shellcheck disable=SC1091
source .local.env
: "${RAIZ_PROJETO:?defina RAIZ_PROJETO em .local.env}"
: "${PM2_APP:?defina PM2_APP em .local.env}"
: "${PM2_LOG_DIR:?defina PM2_LOG_DIR em .local.env}"
: "${PORTA_WA:?defina PORTA_WA em .local.env}"

if [[ "$1" == "--projeto" ]]; then dest="$RAIZ_PROJETO/.claude/skills"; else dest="$HOME/.claude/skills"; fi

mkdir -p "$dest"
rm -rf "$dest/whatsapp-antiban"
cp -r skill/whatsapp-antiban "$dest/"

# Preenche os marcadores só na cópia instalada.
esc() { printf '%s' "$1" | sed -e 's/[\/&|]/\\&/g'; }
find "$dest/whatsapp-antiban" -type f \( -name '*.md' -o -name '*.sh' \) -print0 |
  xargs -0 sed -i \
    -e "s|<RAIZ_PROJETO>|$(esc "$RAIZ_PROJETO")|g" \
    -e "s|<PM2_APP>|$(esc "$PM2_APP")|g" \
    -e "s|<PM2_LOG_DIR>|$(esc "$PM2_LOG_DIR")|g" \
    -e "s|<PORTA_WA>|$(esc "$PORTA_WA")|g"
chmod +x "$dest/whatsapp-antiban/scripts/"*.sh

echo "skill instalada em $dest/whatsapp-antiban (marcadores preenchidos)"
