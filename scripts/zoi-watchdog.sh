#!/bin/bash
# zoi-watchdog.sh — roda NO VPS, cron de 5 em 5 minutos (ticket 009).
#
#   */5 * * * * /root/zoi-watchdog.sh
#
# Existe por causa de um precedente concreto: a imagem `latest` do Evolution GO parou de ser aceita
# pelo WhatsApp (`Client outdated (405)`), o contêiner seguiu `healthy` o tempo todo, e o tráfego
# ficou morto de 2026-04-16 até alguém olhar — TRÊS MESES. Não faltou monitoramento de processo.
# Faltou alguém perguntar se o produto ainda funcionava.
#
# Canal: e-mail pela Resend, reaproveitando o que a API já usa em services/alert.service.ts.
# Alerta por WhatsApp foi recusado — morreria junto com o que monitora.
set -uo pipefail   # sem -e: um sinal que falha não pode abortar a checagem dos outros

ESTADO="/var/lib/zoi-watchdog"
SILENCIO_S=21600   # 6h
# Banco do painel, no Postgres DO HOST — não no hub_postgres. A estrutura do provedor não é tocada:
# o banco do Hub segue apenas lido, pelo mesmo `docker exec` de sempre. Variável para que o
# test-watchdog.sh aponte para um banco descartável.
WATCHDOG_DB="${WATCHDOG_DB:-watchdog}"
# Dois limiares, e não um: `wait` é profundidade de fila e `failed` é dano acumulado. Um número só
# para os dois deixou `bull:inbound-messages:failed = 1` passar calado (medido em 2026-08-05), e
# job morto não escoa sozinho — ele fica.
LIMIAR_FILA_FAILED=0    # qualquer job morto alerta
# Arbitrado, não derivado: no pico jamais registrado de 36 msg/h são ~33 min de acúmulo sem escoar,
# o que na carga de hoje só acontece com worker parado.
LIMIAR_FILA_WAIT=20
LIMIAR_DISCO=85
# Percentual do `max_connections` do evogo_auth. 70 de 100 deu cerca de um dia de folga no ritmo
# medido em 2026-08-04 — o bastante para agendar a reconexão dos números em vez de sofrê-la.
LIMIAR_POOL=70

source /root/zoi-hub/.env 2>/dev/null || true
# GLOBAL_API_KEY mora no .env do EVOLUTION, que é outro arquivo de outro compose. Sem esta linha o
# guard da checagem 3 nunca passa e o sinal que custou três meses fica desligado em silêncio.
GLOBAL_API_KEY="$(grep -h '^GLOBAL_API_KEY=' /root/evolution/.env 2>/dev/null | cut -d= -f2- || true)"
mkdir -p "$ESTADO"

# ANTIRRUÍDO, e ele é obrigatório, não refinamento: um watchdog que manda e-mail a cada 5 minutos
# treina todo mundo a filtrar a caixa — e a partir daí ele não existe mais, só consome atenção.
# Alerta ignorado é pior que nenhum, porque dá sensação de cobertura.
# Grava o estado da checagem no banco que alimenta o painel. Não substitui o e-mail: enriquece.
#
# MELHOR ESFORÇO ABSOLUTO, e o `return 0` no fim é o que garante isso. A regra que o script inteiro
# segue (`set -uo pipefail` SEM `-e`) é que uma checagem que falha não pode abortar as outras — e
# aqui vale em dobro, porque o e-mail é o canal que sobrevive ao banco. Um Postgres fora do ar não
# pode ser o motivo de ninguém ser avisado de que o Postgres está fora do ar.
#
# `timeout 5` pelo mesmo motivo: o cron usa `flock -n`, então um psql pendurado não empilha ciclos
# — ele impede TODOS os seguintes de rodar, e a vigilância para sem que nada acuse.
#
# Os valores vão por `-v` e são interpolados com `:'nome'`, que é o psql quem escapa. Nunca por
# concatenação: o corpo dos alertas é português escrito à mão e já contém aspas hoje.
registrar() {
  local chave="$1" est="$2" assunto="${3:-}" corpo="${4:-}"
  timeout 5 sudo -u postgres psql -d "$WATCHDOG_DB" -q -v ON_ERROR_STOP=1 \
    -v chave="$chave" -v est="$est" -v assunto="$assunto" -v corpo="$corpo" <<'SQL' >/dev/null 2>&1
INSERT INTO estado (chave, estado, assunto, corpo, desde, medido_em)
VALUES (:'chave', :'est', :'assunto', :'corpo', now(), now())
ON CONFLICT (chave) DO UPDATE SET
  estado    = EXCLUDED.estado,
  assunto   = EXCLUDED.assunto,
  corpo     = EXCLUDED.corpo,
  -- `desde` só se move quando o estado MUDA. É o que responde "há quanto tempo", que o e-mail
  -- nunca soube responder: alerta de quatro horas e alerta de quatro minutos pedem reações
  -- diferentes, e hoje os dois chegam iguais.
  desde     = CASE WHEN estado.estado = EXCLUDED.estado THEN estado.desde ELSE EXCLUDED.desde END,
  medido_em = EXCLUDED.medido_em;
SQL
  return 0
}

alertar() {
  local chave="$1" assunto="$2" corpo="$3"
  local marca="$ESTADO/$chave"
  # ANTES da guarda de antirruído, e isso não é ordem à toa. O e-mail cala por 6h de propósito, mas
  # o problema segue de pé — e uma TV que apagasse o alerta porque o e-mail já foi mandado mentiria
  # exatamente durante as 6 horas em que ele mais importa.
  registrar "$chave" ALERTA "$assunto" "$corpo"
  if [ -f "$marca" ] && [ $(( $(date +%s) - $(stat -c %Y "$marca") )) -lt "$SILENCIO_S" ]; then
    return
  fi
  touch "$marca"
  [ -n "${RESEND_API_KEY:-}" ] || { echo "[sem RESEND_API_KEY] $assunto: $corpo"; return; }
  # A resposta da Resend é CONFERIDA, e não descartada. Descartá-la já custou caro do outro lado
  # deste mesmo `if`: as variáveis de alerta ficaram ausentes do .env por semanas e o watchdog
  # engoliu cinco alertas reais — entre eles o "WhatsApp desconectado" das duas conexões no dia do
  # incidente de 2026-08-04. Um canal que falha calado é pior que canal nenhum, porque o silêncio
  # passa por saúde. Recusa comum: `from` num domínio não verificado devolve 403.
  local http
  http=$(curl -s -o /tmp/zoi-watchdog-resend.json -w '%{http_code}' -X POST https://api.resend.com/emails \
    -H "Authorization: Bearer $RESEND_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(printf '{"from":"%s","to":"%s","subject":"[ZOI Hub] %s","html":"<p>%s</p>"}' \
          "${ALERT_FROM_EMAIL:-alertas@zoi.com.br}" "${ALERT_TO_EMAIL:?defina ALERT_TO_EMAIL}" \
          "$assunto" "$corpo")")
  if [ "$http" != "200" ]; then
    # Sem a marca, o próximo ciclo tenta de novo em 5 minutos em vez de silenciar por 6 horas.
    rm -f "$marca"
    echo "[Resend recusou: HTTP $http] $assunto: $corpo"
    cut -c1-300 /tmp/zoi-watchdog-resend.json 2>/dev/null
  fi
  rm -f /tmp/zoi-watchdog-resend.json
}

resolvido() { rm -f "$ESTADO/$1"; registrar "$1" OK "" ""; }

# Atalho para as funções abaixo: todas gravam no banco do painel e nenhuma pode derrubar o ciclo.
watchdog_psql() { timeout 10 sudo -u postgres psql -d "$WATCHDOG_DB" -q -v ON_ERROR_STOP=1 "$@" >/dev/null 2>&1; return 0; }

# Erros do log da API para o painel de rodapé.
#
# Existe porque `docker logs` é efêmero e morre no deploy. No diagnóstico de 2026-09-05 havia só 2h
# de histórico porque o contêiner tinha sido recriado — justamente a janela que interessava.
#
# `python3` e não `jq`: o servidor tem o primeiro e não o segundo, e instalar pacote para ler JSON
# num script de cron é dependência nova a manter para sempre.
#
# Nível 40 (aviso) entra junto com 50 e 60. Não é ruído: os sinais que precederam o incidente de
# 2026-09-05 eram todos avisos — "sem inbound anterior" e as rejeições de merge. Erro de verdade a
# API quase não produz (zero em 24h medido em 2026-09-06), e um painel que só mostra 50+ ficaria
# permanentemente vazio, que é o mesmo que não existir.
coletar_erros() {
  local conteiner="$1"
  local tsv
  tsv=$(mktemp) || return 0

  # Janela maior que o intervalo do cron de propósito, para não abrir buraco entre ciclos. O custo
  # é duplicata na fronteira, desfeita pelo índice único de `erro`.
  docker logs --since 6m "$conteiner" 2>&1 | python3 -c '
import sys, json, datetime

for linha in sys.stdin:
    linha = linha.strip()
    if not linha.startswith("{"):
        continue
    try:
        d = json.loads(linha)
    except ValueError:
        continue
    nivel = d.get("level")
    if not isinstance(nivel, int) or nivel < 40:
        continue
    ms = d.get("time")
    if not isinstance(ms, (int, float)):
        continue
    quando = datetime.datetime.fromtimestamp(ms / 1000, datetime.timezone.utc).isoformat()
    # Só `msg`. O resto da linha carrega telefone de cliente e não entra no banco que a parede lê.
    msg = str(d.get("msg", ""))[:500].replace("\t", " ").replace("\n", " ").replace("\\", " ")
    if not msg:
        continue
    print(f"{quando}\t{nivel}\t{msg}")
' > "$tsv" 2>/dev/null

  if [ -s "$tsv" ]; then
    # Tabela temporária + ON CONFLICT DO NOTHING: `\copy` sozinho não sabe ignorar duplicata, e a
    # duplicata é garantida pela janela sobreposta.
    watchdog_psql <<SQL
CREATE TEMP TABLE tmp_erro (ocorrido_em timestamptz, nivel int, mensagem text);
\copy tmp_erro FROM '$tsv'
INSERT INTO erro (ocorrido_em, nivel, mensagem)
SELECT ocorrido_em, nivel, mensagem FROM tmp_erro
ON CONFLICT DO NOTHING;
SQL
  fi
  rm -f "$tsv"
  return 0
}

# Foto das conexões para a grade do painel.
#
# Copiada para o banco do vigia, e não lida do Hub na hora: assim o Grafana nunca abre conexão com
# o banco do provedor. A leitura do Hub acontece só aqui, e só SELECT — pelo mesmo `docker exec`
# que a checagem 3 já usava.
coletar_conexoes() {
  local tsv
  tsv=$(mktemp) || return 0

  docker exec hub_postgres psql -U postgres -d hub -tA -F$'\t' -c "
    SELECT c.id,
           coalesce(nullif(c.label, ''), c.\"whatsappNumber\"),
           c.\"whatsappNumber\",
           c.status,
           (SELECT max(m.\"createdAt\")
              FROM \"MessageLog\" m
             WHERE m.\"connectionId\" = c.id AND m.direction = 'INBOUND')
      FROM \"Connection\" c" 2>/dev/null \
    | grep -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' > "$tsv"
  # O filtro ancora no formato do UUID e NÃO na tabulação que separa as colunas: `grep -E` não
  # interpreta `\t`, e a versão que tentava isso descartava todas as linhas em silêncio — a grade
  # ficava vazia sem erro nenhum, que é o modo de falhar que este repositório inteiro combate.
  # Serve para descartar o rodapé do psql e qualquer aviso que escape para o stdout.

  if [ -s "$tsv" ]; then
    watchdog_psql <<SQL
CREATE TEMP TABLE tmp_conexao (connection_id text, rotulo text, numero text, status text, ultimo_inbound_em timestamptz);
\copy tmp_conexao FROM '$tsv' NULL ''
INSERT INTO conexao_snapshot (connection_id, rotulo, numero, status, ultimo_inbound_em, medido_em)
SELECT connection_id, rotulo, numero, status, ultimo_inbound_em, now() FROM tmp_conexao
ON CONFLICT (connection_id) DO UPDATE SET
  rotulo            = EXCLUDED.rotulo,
  numero            = EXCLUDED.numero,
  status            = EXCLUDED.status,
  ultimo_inbound_em = EXCLUDED.ultimo_inbound_em,
  medido_em         = EXCLUDED.medido_em;
-- Conexão apagada no Hub some da grade. Sem isto ela ficaria para sempre na parede, verde e
-- inexistente.
DELETE FROM conexao_snapshot WHERE medido_em < now() - interval '1 hour';
SQL
  fi
  rm -f "$tsv"
  return 0
}

# Retenção. Sem isto as duas tabelas crescem para sempre num servidor onde o disco já é vigiado
# pela checagem 4 deste mesmo script.
podar() {
  watchdog_psql -c "DELETE FROM erro WHERE ocorrido_em < now() - interval '7 days'; DELETE FROM execucao WHERE rodou_em < now() - interval '7 days';"
  return 0
}

# HEARTBEAT — a peça que impede o painel de mentir.
#
# O watchdog não consegue vigiar a si mesmo. Se o cron parar, ou se o script morrer no meio, a
# última foto gravada permanece — e uma TV toda verde alimentada por dado velho é pior que TV
# apagada, porque AFIRMA saúde em vez de admitir ignorância. O Grafana pinta tudo de vermelho se
# `max(rodou_em)` passar de 12 minutos.
#
# Chamada na ÚLTIMA linha do script, nunca antes: gravada no começo, ela diria "rodou" para um
# ciclo que abortou na terceira checagem — exatamente a mentira que ela existe para impedir.
bater_ponto() {
  watchdog_psql -c "INSERT INTO execucao (rodou_em) VALUES (now());"
  return 0
}

# Daqui para baixo é o ciclo de checagens. O test-watchdog.sh carrega só as funções acima: sem esta
# linha, um `source` dispararia as checagens contra produção — mandando e-mail de verdade e mexendo
# no estado real só por ter sido importado.
[ "${WATCHDOG_SO_FUNCOES:-}" = "1" ] && return 0

# Cor ativa do blue/green — resolvida UMA VEZ aqui, no topo, e usada o ciclo inteiro. Nunca lida de
# novo mais abaixo nem guardada entre ciclos: o deploy troca a cor no meio de um ciclo de 5 min, e
# reler no meio do ciclo é o mesmo risco de usar uma velha. Interpolar `$(hub-logs cor)` dentro de
# cada string maior não pararia o script sob falha (a mesma armadilha do próprio hub-logs, tickets
# 007/008): por isso ela sai numa variável e é validada ANTES de qualquer uso.
COR="$(hub-logs cor 2>/dev/null)" || COR=""
case "$COR" in
  blue|green) resolvido cor-ilegivel ;;
  *)
    alertar cor-ilegivel "Watchdog não leu a cor ativa" \
      "hub-logs cor falhou ou devolveu '${COR:-vazia}'. Os itens que dependem de hub_api_*/hub_frontend_* ficam CEGOS até isto ser corrigido — o resto do watchdog (fila, disco, TLS, pool, Postgres/Redis/Evolution) segue vigiando normalmente."
    COR=""
    ;;
esac

# 1. API — /health já cobre Postgres E Redis desde o ticket 005.
# Mede pelo nginx, e não por `127.0.0.1:4000`, desde 2026-09-01: com azul e verde a porta fixa
# mediria sempre uma cor, e alertaria "API fora" toda vez que a outra estivesse ativa. Pelo nginx
# mede-se o que o cliente vê, que é a única pergunta que importa.
if curl -sf --max-time 10 https://api.appzoi.com/health >/dev/null 2>&1; then
  resolvido api-fora
else
  alertar api-fora "API fora" "GET /health não respondeu 200. Ver: hub-logs api"
fi

# 2. Fila entupida. Lida direto no Redis: o watchdog roda no host e já tem docker exec, então criar
# rota autenticada de métricas seria superfície nova para o mesmo dado.
#
# O comando MUDA com o estado, e isso não é detalhe: no BullMQ `wait` é lista e `failed` é ZSET.
# `LLEN` num ZSET devolve `WRONGTYPE ...` no lugar de um número, `n` vira essa frase, e o `[ -gt ]`
# abaixo erra em vez de comparar — com `set +e`, sem abortar nada. O sinal de `failed` ficou assim
# desde a instalação (2026-07-31) até 2026-08-05: dois jobs mortos em produção, zero alerta, e a
# única pista era uma linha de erro do bash no /var/log/zoi-watchdog.log que ninguém lia.
# Por isso também a guarda de "é número mesmo": o próximo tipo errado alerta em vez de calar.
for fila in inbound-messages outbound-messages; do
  for estado in wait failed; do
    # O comando E o limiar saem do mesmo `case`, de propósito: separados, um pode ser trocado sem
    # o outro, e a combinação errada (ZCARD com limiar de fila) é justamente o que ficou calado.
    case "$estado" in
      failed) comando=ZCARD; limiar=$LIMIAR_FILA_FAILED ;;
      *)      comando=LLEN;  limiar=$LIMIAR_FILA_WAIT   ;;
    esac
    n=$(docker exec hub_redis redis-cli "$comando" "bull:$fila:$estado" 2>/dev/null || echo 0)
    if [[ ! "$n" =~ ^[0-9]+$ ]]; then
      alertar "fila-$fila-$estado-ilegivel" "Watchdog não leu a fila $fila/$estado" \
        "$comando devolveu '$n'. O sinal está CEGO até isto ser corrigido."
    elif [ "${n:-0}" -gt "$limiar" ]; then
      alertar "fila-$fila-$estado" "Fila $fila: $n em $estado" \
        "Acima do limiar de $limiar para $estado. Ver o Bull Board em /admin/queues."
    else
      resolvido "fila-$fila-$estado"
      resolvido "fila-$fila-$estado-ilegivel"
    fi
  done
done

# 3. Sessão de WhatsApp caída — O SINAL QUE CUSTOU TRÊS MESES.
#
# Polling de propósito, e não confiança no webhook de desconexão: o webhook EXISTE
# (routes/webhooks/evolution.ts:161) e ficou mudo naquele incidente. Ele segue valendo como caminho
# rápido; isto aqui é a rede embaixo dele.
#
# A consulta sai de DENTRO da rede, via `docker exec hub_api_$COR`, e não do host: o `evolution_go` de
# produção não publica porta nenhuma (medido em 2026-07-31), e `EVOLUTION_API_URL` vale
# `http://evolution-go:8080` — nome que o host não resolve. Rodando daqui, o curl falharia, a
# variável sairia vazia, o `else` marcaria como resolvido, e este bloco ficaria desligado em
# silêncio. Pior que não ter watchdog: parece que tem.
#
# E `127.0.0.1:8080` no host NÃO é a Evolution — é contêiner de vizinho, que responde JSON de erro.
if [ -n "${EVOLUTION_API_URL:-}" ] && [ -n "${GLOBAL_API_KEY:-}" ] && [ -n "$COR" ]; then
  ids=$(docker exec hub_postgres psql -U postgres -d hub -tAc \
    "SELECT \"evolutionInstanceId\" FROM \"Connection\" WHERE status = 'CONNECTED'" 2>/dev/null || true)
  for id in $ids; do
    resposta=$(docker exec "hub_api_$COR" sh -c \
      "curl -s --max-time 10 -H 'apikey: $GLOBAL_API_KEY' '$EVOLUTION_API_URL/instance/info/$id'" 2>/dev/null || true)
    # Resposta vazia é FALHA DE CONSULTA, não sessão viva: sem esta distinção, Evolution fora do ar
    # apaga a marca de todo mundo e o alerta some junto com o que deveria denunciar.
    if [ -z "$resposta" ]; then
      alertar evolution-inalcancavel "Evolution não respondeu" \
        "GET /instance/info falhou de dentro da rede. As sessões não puderam ser verificadas."
      continue
    fi
    resolvido evolution-inalcancavel
    conectado=$(printf '%s' "$resposta" | grep -o '"connected":[a-z]*' | cut -d: -f2)
    if [ "$conectado" = "false" ]; then
      alertar "sessao-$id" "WhatsApp desconectado" \
        "A conexão $id está CONNECTED no painel e desconectada na Evolution. Reconectar por QR."
    else
      resolvido "sessao-$id"
    fi
  done
fi

# 4. Disco.
uso=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if [ "${uso:-0}" -gt "$LIMIAR_DISCO" ]; then
  alertar disco "Disco em ${uso}%" "Acima de ${LIMIAR_DISCO}%. Ver: du -sh /var/lib/docker/*"
else
  resolvido disco
fi

# 5. Morte por OOM e laço de reinício (ticket 011). Sem isto, o contêiner reinicia sozinho
# (`restart: unless-stopped`) e o incidente vira "sumiu sozinho" — o mesmo formato do apagão de
# três meses.
CONTEINERES="hub_postgres hub_redis evolution_go evolution_postgres"
# Os dois de cor só entram se COR foi lida — nome com cor vazia (`hub_api_`) não existe e só
# poluiria o ciclo com falso "reiniciando em laço" vindo do próprio `docker inspect` falhando.
[ -n "$COR" ] && CONTEINERES="hub_api_$COR hub_frontend_$COR $CONTEINERES"
for c in $CONTEINERES; do
  oom=$(docker inspect "$c" --format '{{.State.OOMKilled}}' 2>/dev/null || echo false)
  [ "$oom" = "true" ] && alertar "oom-$c" "$c morto por OOM" \
    "O kernel matou $c por falta de memória. Ver mem_limit no compose (ticket 011)."
  n=$(docker inspect "$c" --format '{{.RestartCount}}' 2>/dev/null || echo 0)
  [ "${n:-0}" -gt 5 ] && alertar "restart-$c" "$c reiniciando em laço" \
    "RestartCount=$n. A migração saiu do CMD (tarefa 4) — não é mais suspeita. Ver OOM, falha no boot da aplicação ou dependência indisponível (Postgres/Redis). 'hub-logs api' para o log da cor."
done

# 6. TLS. O certbot.timer está saudável (medido em 2026-07-31), mas silêncio dele é
# indistinguível de sucesso.
for dominio in hub.appzoi.com hub.appzoi.com.br api.appzoi.com; do
  fim=$(openssl s_client -connect "$dominio:443" -servername "$dominio" </dev/null 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  [ -z "$fim" ] && continue
  dias=$(( ( $(date -d "$fim" +%s) - $(date +%s) ) / 86400 ))
  if [ "$dias" -lt 10 ]; then
    alertar "tls-$dominio" "Certificado de $dominio expira em ${dias}d" \
      "Conferir: systemctl status certbot.timer"
  else
    resolvido "tls-$dominio"
  fi
done

# 7. Entrega da Evolution recusada no limite do webhook — A ENTRADA QUE MORRE EM SILÊNCIO.
#
# Precedente concreto (2026-07-30 a 2026-08-03): a Evolution guardava a URL do 554791744143 com o
# segredo truncado nos 10 primeiros caracteres dos 32, `segredosConferem` recusava tudo, e a entrada
# daquele número ficou morta QUATRO DIAS. Nada acendeu: o contêiner `healthy`, a sessão conectada na
# Evolution, `/health` verde, saída funcionando, 185 descartes por dia só no log. As checagens 1 a 3
# passariam todas — nenhuma delas pergunta se a mensagem do cliente chegou ao CRM.
#
# Descarte aqui não é evento normal: em operação saudável este contador é ZERO. Por isso o limiar é
# `> 0`, e é o antirruído de 6h que impede um pico de virar enxurrada de e-mail.
#
# `conexão ainda sem segredo` NÃO entra: aquele aviso é de conexão pré-2026-07-28 que segue
# funcionando, e ele repete a cada entrega legítima. Incluí-lo alertaria sobre o normal.
if [ -n "$COR" ]; then
  descartes=$(docker logs --since 10m "hub_api_$COR" 2>&1 \
    | grep -cE "segredo não confere|recusa a rota sem segredo|instância desconhecida, entrega descartada" \
    || true)
  if [ "${descartes:-0}" -gt 0 ]; then
    alertar webhook-descartado "Mensagens recebidas descartadas: $descartes em 10 min" \
      "O Hub está RECUSANDO entregas da Evolution no limite do webhook, então mensagens de cliente não chegam ao CRM. Quase sempre a webhookUrl da Evolution divergiu do banco. Conserto: abrir o número no painel e clicar em Reconectar. Ver: hub-logs api | grep 'entrega descartada'"
  else
    resolvido webhook-descartado
  fi
fi

# 8. Pool do Postgres da Evolution enchendo — A CAUSA ÚNICA DE DOIS SINTOMAS.
#
# A Evolution GO abre um pool a cada start de client de WhatsApp e nunca o devolve. Quando as
# conexões batem no `max_connections = 100`, ela para de subir client: o QR não nasce E o envio
# falha com 500, ao mesmo tempo, sem nada ligar um ao outro. Foi o incidente de 2026-08-04, onde a
# receita de recuperação já estava no runbook desde 2026-07-29 e mesmo assim o caso foi descoberto
# pela reclamação do usuário — 99 conexões `idle` acumuladas ao longo de quatro dias.
#
# Medir aqui, e não na API: o comando é o mesmo `docker exec` que o runbook manda rodar, o host já
# alcança o contêiner, e a alternativa custaria à API a senha do banco da Evolution só para contar
# linha. O que se vigia é uma coisa do servidor, não do produto.
#
# O stderr é capturado JUNTO, e isso é o oposto de descuido: com o pool cheio o próprio `psql` é
# recusado (`FATAL: sorry, too many clients already`, até para superusuário — está documentado na
# seção do runbook). Medindo só o stdout, a checagem ficaria muda exatamente no momento que ela
# existe para denunciar, e o silêncio pareceria saúde.
#
# Qualquer outra saída não numérica sai calada de propósito: Postgres da Evolution fora do ar já
# derruba a Evolution inteira, e a checagem 3 alerta por isso com o texto certo. Alertar duas vezes
# pela mesma coisa é o começo de virar ruído.
CONSERTO_POOL="Conserto: docker restart evolution_go e depois Reconectar cada número no painel, porque as instâncias não voltam sozinhas. Ver 'A Evolution GO vaza conexões de Postgres' no runbook."
pool=$(docker exec evolution_postgres psql -U postgres -d evogo_auth -tAc \
  "SELECT (SELECT count(*) FROM pg_stat_activity WHERE datname = current_database()), current_setting('max_connections')" 2>&1 || true)
# A medida é pescada por linha, e não lida do bloco inteiro: este `psql` imprime um WARNING de
# collation version em toda invocação (medido em produção em 2026-08-04), e como o stderr vem junto,
# tratar a saída como um valor só faria a expansão pegar o texto do aviso em vez dos números.
medida=$(printf '%s' "$pool" | grep -E '^[0-9]+\|[0-9]+$' | tail -1)
if printf '%s' "$pool" | grep -q 'too many clients'; then
  alertar pool-evolution "Pool do Postgres da Evolution ESGOTADO" \
    "O banco evogo_auth recusa conexão nova, inclusive a desta checagem. A Evolution não sobe mais nenhum client: o QR não nasce e o envio falha com 500, ao mesmo tempo. $CONSERTO_POOL"
elif [ -n "$medida" ]; then
  usadas=${medida%%|*}
  teto=${medida##*|}
  if [ $(( usadas * 100 / teto )) -ge "$LIMIAR_POOL" ]; then
    alertar pool-evolution "Pool do Postgres da Evolution em $usadas/$teto" \
      "A Evolution vaza uma conexão por start de client e para de subir client ao bater no teto — QR não nasce e envio falha com 500 juntos. $CONSERTO_POOL"
  else
    resolvido pool-evolution
  fi
fi

# 9. logrotate por cima do log do Docker — O BURACO MUDO.
#
# Em 2026-08-26 um `/etc/logrotate.d/docker-containers` com `copytruncate`, criado por fora de
# qualquer deploy nosso, zerava o arquivo que o Docker ainda escrevia e deixava bytes NUL no começo
# do log: o `docker logs` batia neles e parava calado, em 17 dos 55 contêineres. A config foi
# apagada, mas nada impede que volte — e o sintoma não tem erro nenhum. Duas perguntas: existe de
# novo uma config apontando para `docker/containers`? E o log da cor ativa começa com `{`?
# Ver "docker logs para no meio" no runbook.
rotacao=$(grep -rl 'docker/containers' /etc/logrotate.d/ /etc/logrotate.conf 2>/dev/null | tr '\n' ' ')
if [ -n "$rotacao" ]; then
  alertar logrotate-docker "logrotate apontando para os logs do Docker: $rotacao" \
    "Essa config já quebrou o docker logs em 2026-08-26 (copytruncate por cima da rotação do próprio Docker). Apague-a e confira os logs com: head -c 1 \$(docker inspect --format '{{.LogPath}}' hub_api_$COR) | od -c"
else
  resolvido logrotate-docker
fi
for c in hub_api_$COR evolution_go; do
  caminho=$(docker inspect --format '{{.LogPath}}' "$c" 2>/dev/null || true)
  [ -n "$caminho" ] && [ -s "$caminho" ] || continue
  if [ "$(head -c 1 "$caminho" | od -An -c | tr -d ' ')" = '\\0' ]; then
    alertar log-furado-$c "Log do $c começa com NUL — docker logs vai parar no meio" \
      "Buraco de bytes NUL no começo de $caminho, o sintoma do logrotate de 2026-08-26. Conserto no runbook, 'docker logs para no meio'."
  else
    resolvido log-furado-$c
  fi
done

# --- alimentação do painel ---------------------------------------------------
#
# Depois de TODAS as checagens, e nesta ordem. Nada aqui alerta nem manda e-mail: só alimenta a
# tela. Uma falha em qualquer uma delas é engolida de propósito — o painel pode ficar defasado, a
# vigilância não pode parar por causa dele.

[ -n "$COR" ] && coletar_erros "hub_api_$COR"
coletar_conexoes
podar

# ÚLTIMA LINHA DO SCRIPT. Ver o comentário de bater_ponto(): a posição é o que dá sentido ao sinal.
bater_ponto
