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

sed "s|SENHA_AQUI|$GRAFANA_TV_PASSWORD|" \
  "$REPO_DIR/grafana/datasource-watchdog.yaml.exemplo" > "$PROV_DS/watchdog.yaml" \
  || erro "falhou ao escrever $PROV_DS/watchdog.yaml"

# DONO E MODO COPIADOS DO ARQUIVO QUE JÁ FUNCIONA, nunca escolhidos aqui.
#
# O arquivo tem senha, então 0600 está certo — mas 0600 pertencente ao ROOT é ilegível para o
# usuário do Grafana (uid 472) dentro do contêiner, e o provisionamento não degrada: ele DERRUBA o
# Grafana em laço de reinício. Em 2026-09-06 isso tirou do ar, por quatro minutos, o Grafana que é
# compartilhado com o All Watcher. Espelhar o vizinho acerta dono e modo de uma vez, e continua
# certo se um dia a imagem mudar de uid.
chown --reference="$PROV_DS/allwatcher.yaml" "$PROV_DS/watchdog.yaml" 2>/dev/null \
  || erro "não consegui dar a posse de watchdog.yaml ao usuário do Grafana"
chmod --reference="$PROV_DS/allwatcher.yaml" "$PROV_DS/watchdog.yaml" 2>/dev/null \
  || erro "não consegui ajustar o modo de watchdog.yaml"

cp "$REPO_DIR/grafana/zoi-hub-tv.json" "$DASH/zoi-hub-tv.json" \
  || erro "falhou ao copiar o dashboard"
chown --reference="$DASH/allwatcher.json" "$DASH/zoi-hub-tv.json" 2>/dev/null || true
chmod --reference="$DASH/allwatcher.json" "$DASH/zoi-hub-tv.json" 2>/dev/null || true

# O provisionamento só é lido no boot. `restart` e não `up -d`: o contêiner é preservado.
docker restart grafana_allwatcher >/dev/null || erro "falhou ao reiniciar o Grafana"

# CONFERIR QUE VOLTOU. Sem isto, um provisionamento inválido deixa o Grafana em laço de reinício e
# o instalador imprime o link como se tudo tivesse dado certo — inclusive o painel do All Watcher,
# que é de outra pessoa, teria sumido em silêncio.
for _ in $(seq 1 30); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3003/api/health)" = "200" ] && break
  sleep 2
done
if [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3003/api/health)" != "200" ]; then
  echo "ERRO: o Grafana não voltou. Últimas linhas:" >&2
  docker logs --tail 15 grafana_allwatcher 2>&1 | grep -i error >&2
  echo "Para desfazer: rm -f $PROV_DS/watchdog.yaml $DASH/zoi-hub-tv.json && docker restart grafana_allwatcher" >&2
  exit 1
fi

echo "Datasource: $PROV_DS/watchdog.yaml"
echo "Dashboard:  $DASH/zoi-hub-tv.json"
echo "Grafana reiniciado."
echo
echo "Painel:  https://api.appzoi.com/grafana/d/zoi-hub-tv"
echo "Modo TV: https://api.appzoi.com/grafana/d/zoi-hub-tv?kiosk&refresh=30s"
