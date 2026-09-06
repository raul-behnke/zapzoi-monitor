#!/bin/bash
# instalar-painel.sh — provisiona o datasource e o dashboard no Grafana que já roda no servidor.
#
# O Grafana é compartilhado com o All Watcher e foi criado por `docker run` sem compose — não há
# arquivo que descreva como recriá-lo. Por isso aqui só se ESCREVE em provisioning e se dá
# `docker restart`: nada que exija remover o contêiner, porque remover sem saber recriar é uma
# viagem só de ida.
#
# A senha do grafana_tv sai de /root/.zapzoi-monitor.env e nunca entra no git.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROV_DS="/etc/grafana-allwatcher/provisioning/datasources"
DASH="/etc/grafana-allwatcher/dashboards"
ENV_FILE="/root/.zapzoi-monitor.env"

erro() { echo "ERRO: $*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || erro "não achei $ENV_FILE (senha do grafana_tv)"
# shellcheck source=/dev/null
source "$ENV_FILE"
[ -n "${GRAFANA_TV_PASSWORD:-}" ] || erro "GRAFANA_TV_PASSWORD vazia em $ENV_FILE"

[ -d "$PROV_DS" ] || erro "não achei $PROV_DS — o Grafana está instalado?"
[ -d "$DASH" ]    || erro "não achei $DASH"

# O JSON é validado ANTES de ser copiado. Dashboard quebrado não derruba o Grafana, mas some da
# lista sem dizer por quê — e um painel que sumiu parece painel que nunca existiu.
python3 -c "import json,sys; json.load(open('$REPO_DIR/grafana/zoi-hub-tv.json'))" \
  || erro "grafana/zoi-hub-tv.json não é JSON válido"

umask 077
sed "s|SENHA_AQUI|$GRAFANA_TV_PASSWORD|" \
  "$REPO_DIR/grafana/datasource-watchdog.yaml.exemplo" > "$PROV_DS/watchdog.yaml" \
  || erro "falhou ao escrever $PROV_DS/watchdog.yaml"

umask 022
cp "$REPO_DIR/grafana/zoi-hub-tv.json" "$DASH/zoi-hub-tv.json" \
  || erro "falhou ao copiar o dashboard"

# O provisionamento só é lido no boot. `restart` e não `up -d`: o contêiner é preservado.
docker restart grafana_allwatcher >/dev/null || erro "falhou ao reiniciar o Grafana"

echo "Datasource: $PROV_DS/watchdog.yaml"
echo "Dashboard:  $DASH/zoi-hub-tv.json"
echo "Grafana reiniciado."
echo
echo "Painel:  https://api.appzoi.com/grafana/d/zoi-hub-tv"
echo "Modo TV: https://api.appzoi.com/grafana/d/zoi-hub-tv?kiosk&refresh=30s"
