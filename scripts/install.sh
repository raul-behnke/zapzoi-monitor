#!/bin/bash
# install.sh — leva o watchdog deste repositório para /root/zoi-watchdog.sh, que é o caminho que o
# cron executa.
#
# Existe porque a alternativa é editar o servidor à mão, e foi exatamente assim que a cópia do
# repositório ficou três versões atrás da que rodava: sem blue/green, sem a separação wait/failed,
# sem a checagem do logrotate. Ninguém decidiu divergir — a divergência é o que acontece quando
# copiar é mais trabalhoso que editar no lugar.
#
# Uso:
#   ./scripts/install.sh              # instala o que está no repositório
#   ./scripts/install.sh --dry-run    # mostra o diff e não escreve nada
#   ./scripts/install.sh --rollback   # volta para o backup mais recente
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIGEM="$REPO_DIR/scripts/zoi-watchdog.sh"
DESTINO="/root/zoi-watchdog.sh"
BACKUPS="/var/lib/zoi-watchdog/backups"

erro() { echo "ERRO: $*" >&2; exit 1; }

[ -f "$ORIGEM" ] || erro "não achei $ORIGEM"

# A validação vem ANTES de qualquer escrita, e é sintática de propósito: `bash -n` não executa
# nada. Instalar um script com erro de sintaxe desliga a vigilância inteira, e o modo como isso
# apareceria é o pior possível — nenhum alerta, que é indistinguível de tudo saudável.
bash -n "$ORIGEM" || erro "$ORIGEM não passa em bash -n; nada foi escrito"

case "${1:-}" in
  --dry-run)
    if [ -f "$DESTINO" ]; then
      diff -u "$DESTINO" "$ORIGEM" && echo "Nada a fazer: $DESTINO já é igual ao repositório."
    else
      echo "$DESTINO não existe; seria criado."
    fi
    exit 0
    ;;
  --rollback)
    ultimo=$(ls -1t "$BACKUPS"/zoi-watchdog.sh.* 2>/dev/null | head -1)
    [ -n "$ultimo" ] || erro "não há backup em $BACKUPS"
    bash -n "$ultimo" || erro "o backup $ultimo não passa em bash -n; recusando"
    cp "$ultimo" "$DESTINO"
    chmod +x "$DESTINO"
    echo "Voltou para $ultimo"
    exit 0
    ;;
  "") ;;
  *) erro "opção desconhecida: $1" ;;
esac

if [ -f "$DESTINO" ] && cmp -s "$DESTINO" "$ORIGEM"; then
  echo "Nada a fazer: $DESTINO já é igual ao repositório."
  exit 0
fi

# O backup é do que está SAINDO, não do que entra: é ele que o --rollback precisa. Guardado antes
# da cópia porque depois já não existe mais.
if [ -f "$DESTINO" ]; then
  mkdir -p "$BACKUPS"
  backup="$BACKUPS/zoi-watchdog.sh.$(date +%Y%m%d-%H%M%S)"
  cp "$DESTINO" "$backup" || erro "falhou ao guardar backup em $backup"
  echo "Backup: $backup"
  # Poda para os 10 mais recentes. Sem isso o diretório cresce para sempre num servidor onde o
  # disco já é vigiado pela checagem 4 deste mesmo script.
  ls -1t "$BACKUPS"/zoi-watchdog.sh.* 2>/dev/null | tail -n +11 | xargs -r rm -f
fi

cp "$ORIGEM" "$DESTINO" || erro "falhou ao copiar para $DESTINO"
chmod +x "$DESTINO"

# Conferir DEPOIS de escrever: cp pode falhar por disco cheio sem devolver erro em todos os casos,
# e um destino truncado passa em bash -n com a mesma facilidade com que passa um arquivo inteiro.
cmp -s "$DESTINO" "$ORIGEM" || erro "$DESTINO ficou diferente da origem depois da cópia"

echo "Instalado: $DESTINO"
echo "sha256 $(sha256sum "$DESTINO" | cut -d' ' -f1)"
echo
echo "O cron executa este caminho de 5 em 5 minutos. Para conferir agora:"
echo "  $DESTINO"
