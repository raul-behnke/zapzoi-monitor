#!/bin/bash
# test-watchdog.sh — roda NO VPS, contra um banco descartável.
#
#   ./scripts/test-watchdog.sh
#
# O watchdog não tinha teste, e isso é parte do problema que ele mesmo documenta: os dois sinais
# que ficaram CEGOS em produção morreriam num teste de uma linha. O `LLEN` num ZSET devolvia
# `WRONGTYPE ...` no lugar de um número desde a instalação, e ninguém soube por seis dias. O
# segredo do webhook truncado matou a entrada de um número por quatro dias.
#
# Sem framework de propósito: o que se testa aqui é um script de shell que roda em cron num
# servidor, e a dependência a menos é uma coisa a menos para quebrar no dia do incidente.
set -uo pipefail

DB_TESTE="watchdog_teste"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

falhas=0
passou() { echo "  ok   $1"; }
falhou() { echo "  FALHA $1"; echo "       esperado: $2"; echo "       obtido:   $3"; falhas=$((falhas + 1)); }

conferir() {
  local titulo="$1" esperado="$2" obtido="$3"
  [ "$obtido" = "$esperado" ] && passou "$titulo" || falhou "$titulo" "$esperado" "$obtido"
}

psql_teste() { sudo -u postgres psql -d "$DB_TESTE" -tAc "$1" 2>/dev/null; }

# ---- preparo ----------------------------------------------------------------

sudo -u postgres psql -qc "DROP DATABASE IF EXISTS $DB_TESTE" >/dev/null 2>&1
sudo -u postgres psql -qc "CREATE DATABASE $DB_TESTE" >/dev/null 2>&1

# O schema sai do MESMO arquivo que produção usa. Um teste contra um schema escrito à mão passa
# a testar o schema do teste, não o que roda.
sudo -u postgres psql -q -d "$DB_TESTE" -f "$RAIZ/sql/001-schema.sql" >/dev/null 2>&1

# Se o schema não chegou no banco do teste, toda asserção abaixo mediria o vazio e o teste passaria
# a reportar falhas que não existem — ou, pior, o arquivo levaria as tabelas para outro banco.
if [ "$(psql_teste "SELECT to_regclass('estado') IS NOT NULL")" != "t" ]; then
  echo "ERRO: 001-schema.sql não criou as tabelas em $DB_TESTE" >&2
  sudo -u postgres psql -qc "DROP DATABASE IF EXISTS $DB_TESTE" >/dev/null 2>&1
  exit 2
fi

limpar() { sudo -u postgres psql -qc "DROP DATABASE IF EXISTS $DB_TESTE" >/dev/null 2>&1; }
trap limpar EXIT

# Carrega SÓ as funções. Sem isto, `source` dispara as doze checagens contra produção — o teste
# mandaria e-mail de verdade e mexeria no estado real.
export WATCHDOG_SO_FUNCOES=1
export WATCHDOG_DB="$DB_TESTE"
export ESTADO_DIR_TESTE="$(mktemp -d)"
# shellcheck source=/dev/null
source "$RAIZ/scripts/zoi-watchdog.sh"
ESTADO="$ESTADO_DIR_TESTE"

# O source acima leu /root/zoi-hub/.env, que tem a credencial de e-mail de PRODUÇÃO. O teste 7
# chega perto de alertar() de propósito, e a única coisa que o separa de mandar e-mail de verdade é
# a guarda de antirruído. Tirar a chave é o cinto de segurança: se um dia essa guarda mudar, o
# teste falha em vez de escrever para a caixa de alguém.
unset RESEND_API_KEY

echo "registrar()"

# ---- 1. grava o alerta ------------------------------------------------------

registrar "teste-um" ALERTA "Assunto um" "Corpo um"
conferir "grava um ALERTA" "ALERTA" "$(psql_teste "SELECT estado FROM estado WHERE chave='teste-um'")"

# ---- 2. desde preservado quando o estado repete ------------------------------
#
# O caso que dá sentido à coluna: alerta que dura quatro horas e alerta que nasceu agora pedem
# reações diferentes, e o e-mail nunca soube distinguir os dois.

primeiro_desde=$(psql_teste "SELECT desde FROM estado WHERE chave='teste-um'")
sleep 1
registrar "teste-um" ALERTA "Assunto um" "Corpo um de novo"
conferir "desde preservado quando o estado repete" \
  "$primeiro_desde" "$(psql_teste "SELECT desde FROM estado WHERE chave='teste-um'")"

# ---- 3. desde reiniciado quando o estado muda -------------------------------

registrar "teste-um" OK "" ""
segundo_desde=$(psql_teste "SELECT desde FROM estado WHERE chave='teste-um'")
[ "$segundo_desde" != "$primeiro_desde" ] \
  && passou "desde reiniciado quando o estado muda" \
  || falhou "desde reiniciado quando o estado muda" "diferente de $primeiro_desde" "$segundo_desde"

# ---- 4. texto com aspas simples ---------------------------------------------
#
# Não é caso de borda: o corpo dos alertas é português escrito à mão e já contém aspas hoje
# ("recusa a rota sem segredo"). Concatenar SQL em shell quebra aqui, e quebra calado.

registrar "teste-aspas" ALERTA "Aspas' no assunto" "Corpo com ' aspas e \"duplas\" e ; ponto-e-vírgula"
conferir "texto com aspas não quebra o INSERT" \
  "Aspas' no assunto" "$(psql_teste "SELECT assunto FROM estado WHERE chave='teste-aspas'")"

# ---- 5. injeção de SQL não passa --------------------------------------------

registrar "teste-injecao" ALERTA "x'); DROP TABLE estado; --" "corpo"
conferir "tabela sobrevive a tentativa de injeção" \
  "t" "$(psql_teste "SELECT to_regclass('estado') IS NOT NULL")"

# ---- 6. banco fora do ar não derruba o ciclo --------------------------------
#
# A regra que o script inteiro segue (`set -uo pipefail` SEM `-e`): uma checagem que falha não
# pode abortar as outras. Aqui vale em dobro — o e-mail é o canal que sobrevive ao banco, e a
# gravação é o que enriquece, não o que substitui.

WATCHDOG_DB="banco_que_nao_existe" registrar "teste-morto" ALERTA "a" "b"
conferir "banco fora do ar devolve sucesso" "0" "$?"

echo "alertar() e resolvido()"

# ---- 7. alertar grava mesmo silenciado --------------------------------------
#
# O erro fácil e o mais grave: pôr registrar() depois da guarda de antirruído. O e-mail cala por
# 6h de propósito, mas o estado continua verdadeiro — e uma TV que apaga o alerta porque o e-mail
# já foi mandado mente exatamente durante as 6h em que o problema segue de pé.

rm -rf "${ESTADO:?}"/*
touch "$ESTADO/teste-silenciado"   # marca recém-criada => dentro da janela de silêncio
alertar "teste-silenciado" "Assunto silenciado" "Corpo" >/dev/null 2>&1
conferir "alertar grava mesmo dentro da janela de silêncio" \
  "ALERTA" "$(psql_teste "SELECT estado FROM estado WHERE chave='teste-silenciado'")"

# ---- 8. resolvido grava OK --------------------------------------------------

resolvido "teste-silenciado"
conferir "resolvido grava OK" \
  "OK" "$(psql_teste "SELECT estado FROM estado WHERE chave='teste-silenciado'")"

# ---- 9. resolvido apaga a marca de antirruído -------------------------------
#
# Comportamento que já existia e não pode ter sido perdido na mudança.

[ ! -f "$ESTADO/teste-silenciado" ] \
  && passou "resolvido apaga a marca de antirruído" \
  || falhou "resolvido apaga a marca de antirruído" "marca ausente" "marca presente"

echo "bater_ponto() e podar()"

# ---- 10. heartbeat grava ----------------------------------------------------

bater_ponto
conferir "bater_ponto grava uma execução" "1" "$(psql_teste "SELECT count(*) FROM execucao")"

# ---- 11. heartbeat é a última linha do script -------------------------------
#
# A posição é o sinal inteiro: gravado antes das checagens, ele diria "rodou" para um ciclo que
# morreu no meio — e a TV mostraria dado velho como se fosse atual, que é a única falha capaz de
# transformar o painel numa mentira em vez de num alerta ausente.

ultima=$(grep -vE '^\s*(#|$)' "$RAIZ/scripts/zoi-watchdog.sh" | tail -1 | tr -d ' ')
conferir "bater_ponto é a última linha executável" "bater_ponto" "$ultima"

# ---- 12. poda respeita a janela de 7 dias -----------------------------------

psql_teste "INSERT INTO erro (ocorrido_em, nivel, mensagem) VALUES (now() - interval '8 days', 50, 'velho')" >/dev/null
psql_teste "INSERT INTO erro (ocorrido_em, nivel, mensagem) VALUES (now(), 50, 'novo')" >/dev/null
podar
conferir "podar apaga o que passou de 7 dias" "0" "$(psql_teste "SELECT count(*) FROM erro WHERE mensagem='velho'")"
conferir "podar preserva o que está dentro da janela" "1" "$(psql_teste "SELECT count(*) FROM erro WHERE mensagem='novo'")"

# ---- 13. erro não guarda payload --------------------------------------------
#
# A TV fica numa sala. Log de erro do Hub carrega telefone de cliente final, e a garantia de que
# ele não aparece na parede é a coluna não existir.

conferir "tabela erro não tem coluna de payload" "0" \
  "$(psql_teste "SELECT count(*) FROM information_schema.columns WHERE table_name='erro' AND column_name='bruto'")"

echo "coletar_conexoes()"

# ---- 14. a grade sai povoada ------------------------------------------------
#
# Integração de verdade contra o hub_postgres, e não simulação: a primeira versão descartava TODAS
# as linhas porque `grep -E` não interpreta `\t`, e a grade ficava vazia sem erro nenhum. Um teste
# com entrada falsa teria passado — o defeito estava exatamente no pedaço que fala com o Hub.

coletar_conexoes
linhas=$(psql_teste "SELECT count(*) FROM conexao_snapshot")
[ "${linhas:-0}" -gt 0 ] \
  && passou "coletar_conexoes povoa a grade ($linhas conexões)" \
  || falhou "coletar_conexoes povoa a grade" "mais que 0" "$linhas"

# ---- 15. a leitura do provedor é só leitura ---------------------------------
#
# A restrição do projeto: a estrutura do provedor não é tocada. O banco do Hub entra apenas por
# SELECT, e este teste falha se alguém acrescentar escrita.

escritas=$(grep -cE 'docker exec hub_postgres psql.*(INSERT|UPDATE|DELETE|ALTER|CREATE|DROP)' "$RAIZ/scripts/zoi-watchdog.sh")
conferir "nenhuma escrita no banco do provedor" "0" "$escritas"

# ---- resultado --------------------------------------------------------------

rm -rf "$ESTADO_DIR_TESTE"
echo
if [ "$falhas" -eq 0 ]; then
  echo "tudo passou"
  exit 0
fi
echo "$falhas falha(s)"
exit 1
