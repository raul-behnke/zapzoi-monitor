# zapzoi-monitor

Vigilância do ZOI Hub e da Evolution: o script que checa, o schema que guarda o estado e o painel
que mostra numa TV.

## Por que este repositório existe

O `zoi-watchdog.sh` roda em produção desde o ticket 009 e vigia nove coisas. Ele existia em dois
lugares e os dois divergiram: a cópia em `zoi-hub-build/scripts/` ficou três versões atrás da que
roda de verdade em `/root/zoi-watchdog.sh` — sem blue/green, sem a separação `wait`/`failed`, sem
a checagem do logrotate. Alguém editava o servidor, ninguém trazia de volta.

Um vigia que só existe no servidor que ele vigia não tem histórico, não tem revisão e não tem
como voltar atrás. Este repositório é a verdade única dele.

## Estado

O primeiro commit é a cópia VIVA de `/root/zoi-watchdog.sh`, byte a byte, sem melhorias. A cópia
divergente do `zoi-hub-build` foi descartada de propósito: era ficção, e escolher entre as duas
por diff seria escolher entre o que roda e o que alguém achou que rodava.

```
sha256  270184d09c14176b50111d4d72ab63083c117de9336f9d5f488922c23ec4a64b
linhas  291
origem  root@147.79.87.179:/root/zoi-watchdog.sh em 2026-09-06
```

Nada mudou de comportamento. O cron segue apontando para `/root/zoi-watchdog.sh`:

```
*/5 * * * * flock -n /tmp/zoi-watchdog.lock /root/zoi-watchdog.sh >> /var/log/zoi-watchdog.log 2>&1
```

Enquanto o deploy a partir daqui não existir, uma edição neste repositório NÃO chega em produção.
Não edite o servidor direto: foi assim que a divergência nasceu.

## O que vem a seguir

`docs/specs/2026-09-06-painel-de-tv-design.md` — o vigia passa a gravar estado em banco, ganha
três checagens novas (silêncio de inbound, conexão caída, envio falhando) e um painel de Grafana
em modo TV.

## Layout

```
scripts/    o watchdog e, depois, os testes dele
sql/        schema zoi_watchdog
grafana/    datasource e dashboard provisionados
docs/specs/ desenho antes do código
```
