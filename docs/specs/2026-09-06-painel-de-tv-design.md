# Painel de TV — vigia do ZOI Hub exposto numa tela

Data: 2026-09-06
Escopo: ZOI Hub + Evolution
Estado: spec aguardando revisão

## Problema

O `zoi-watchdog.sh` (ticket 009) vigia nove coisas e avisa por e-mail. E-mail tem dois defeitos
para operação: chega para quem assinou e some na caixa. Não existe hoje nenhum lugar onde alguém
que passa pela sala vê, sem clicar em nada, se o produto está funcionando.

O segundo defeito é mais grave e tem precedente. O watchdog guarda estado em `touch` de arquivo
sob `/var/lib/zoi-watchdog`. Passadas as 6h de antirruído, um alerta que continua verdadeiro não
reaparece. Não há histórico, não há "há quanto tempo", não há consulta possível. O estado do
sistema só existe dentro do próprio script, entre uma execução e a seguinte.

E há uma lacuna de cobertura, medida em 2026-09-05: por seis horas a conexão `554792924695` não
recebeu nada, e nenhuma das nove checagens acendeu. Container saudável, `/health` verde, sessão
`connected: true` na Evolution, saída funcionando. A checagem 3 pergunta à Evolution se a sessão
está conectada; ela respondia que sim. Ninguém perguntava se mensagem de cliente estava chegando.

## Não-objetivos

- Não é NOC da VPS. Os outros ~20 contêineres (AutoVip, AMC, Castro, Nick, Vaapty, Veltron,
  disparador, middleware) ficam de fora. Escopo é Hub + Evolution.
- Não é substituto do e-mail. O e-mail continua exatamente como está: quem está longe da TV
  precisa dele.
- Não é visualizador de log. Log rolando numa TV ninguém lê a três metros. O log completo fica
  no `hub-logs`, não na parede.

## Decisão de arquitetura

Não construir motor de criticidade novo. O watchdog já é esse motor, e as nove checagens dele
foram escritas em cima de incidentes reais — o apagão de três meses do `Client outdated (405)`,
os quatro dias de webhook recusado por segredo truncado, as 99 conexões vazadas no pool do
Postgres da Evolution. Reescrever isso em outro lugar seria jogar fora o que custou caro.

A mudança é de saída, não de lógica: `alertar()` e `resolvido()` passam a gravar num banco além
do que já fazem. Como toda checagem passa por essas duas funções, as nove alimentam a tela sem
que eu toque em nenhuma delas.

O Grafana já está instalado, rodando e proxiado em `https://api.appzoi.com/grafana/`. Modo TV
(kiosk), auto-refresh e alerta com cor são nativos. Não há frontend novo neste spec.

## Modelo de dados

Schema `zoi_watchdog` no banco `hub`, criado por SQL puro e fora do Prisma de propósito: o
watchdog é coisa de servidor, não do produto, e o `prisma migrate deploy` não gerencia schema que
não conhece. Assim a vigilância não entra no caminho de deploy da aplicação.

```sql
CREATE SCHEMA IF NOT EXISTS zoi_watchdog;

CREATE TABLE zoi_watchdog.estado (
  chave       text PRIMARY KEY,          -- a mesma chave que alertar()/resolvido() já usam
  estado      text NOT NULL,             -- 'ALERTA' | 'OK'
  assunto     text NOT NULL,
  corpo       text NOT NULL,
  desde       timestamptz NOT NULL,      -- quando ENTROU no estado atual; não muda se repetir
  medido_em   timestamptz NOT NULL
);

CREATE TABLE zoi_watchdog.erro (
  id          bigserial PRIMARY KEY,
  ocorrido_em timestamptz NOT NULL,
  nivel       int NOT NULL,
  mensagem    text NOT NULL,
  bruto       jsonb
);
CREATE INDEX ON zoi_watchdog.erro (ocorrido_em DESC);

CREATE TABLE zoi_watchdog.execucao (
  id        bigserial PRIMARY KEY,
  rodou_em  timestamptz NOT NULL
);
```

`desde` é o campo que o e-mail nunca teve. "Fila entupida" e "fila entupida há 4 horas" pedem
reações diferentes, e hoje não dá para distinguir as duas.

`execucao` existe para o heartbeat da seção seguinte.

Retenção: `erro` e `execucao` podados para 7 dias no fim de cada ciclo. `estado` não cresce —
é uma linha por chave.

## Heartbeat

O watchdog não consegue vigiar a si mesmo. Se o cron parar, ou o script abortar no meio, a última
foto gravada permanece — e uma tela toda verde alimentada por dado velho é o pior estado
possível, pior que tela nenhuma, porque afirma saúde em vez de admitir ignorância.

O Grafana consegue fazer essa pergunta: se `max(rodou_em)` passar de 12 minutos (dois ciclos e
uma folga), o painel inteiro fica vermelho com "watchdog parado". A escrita em `execucao` vai na
ÚLTIMA linha do script, nunca na primeira: gravada no começo, ela diria "rodou" para um ciclo que
abortou na terceira checagem.

## Checagens novas

Três, no padrão das existentes, numeradas na sequência.

### 10. Silêncio de inbound

A lacuna do incidente de 2026-09-05. Para cada conexão `CONNECTED`, a idade do último
`MessageLog` INBOUND.

```
LIMIAR_SILENCIO_MIN=90
JANELA_INICIO=8      # hora local
JANELA_FIM=20
BASELINE_MIN_DIA=5   # inbound/dia nos últimos 7 dias
```

O baseline não é refinamento, é o que torna a checagem utilizável: sem ele, todo número de baixo
movimento alerta para sempre, e uma checagem que sempre alerta é uma checagem desligada. Só entra
conexão que comprovadamente recebe tráfego.

A janela de horário existe pelo mesmo motivo. Silêncio às 3 da manhã é o comportamento correto.

Contra o incidente real: o último inbound foi 20:26. O alerta teria saído às 21:56, contra a
descoberta no dia seguinte por reclamação.

Limiares arbitrados, não derivados — são a primeira aposta e devem ser corrigidos com o que a
tabela `estado` mostrar depois de duas semanas. Ficam num bloco único no topo, junto dos outros.

### 11. Conexão caída no banco

`Connection.status != 'CONNECTED'` há mais de `LIMIAR_CAIDA_MIN=15`. A checagem 3 cobre o caso
inverso (banco diz conectado, Evolution diz que não); esta cobre o banco admitindo a queda sem
que ninguém veja. `PENDING_QR` conta como caída: número esperando pareamento não atende cliente.

Precisa conviver com o repareamento manual — durante um QR legítimo o alerta é verdadeiro e
esperado. O antirruído de 6h já cobre isso; não vou inventar supressão nova.

### 12. Envio falhando

`MessageLog` com `status = 'FAILED'` acima de `LIMIAR_FALHA_ENVIO=3` nos últimos 30 min, por
conexão. A checagem 2 vê a fila do BullMQ; esta vê o envio que a fila entregou e o WhatsApp
recusou — são falhas diferentes, e uma não implica a outra.

## Coleta de erro de log

Mesmo ciclo, linhas `level >= 50` do `hub_api_$COR` dos últimos 5 minutos para
`zoi_watchdog.erro`. Resolve o "logs gerais" sem Loki nem contêiner novo.

Isso também conserta um problema que apareceu no diagnóstico de 2026-09-05: o `docker logs` é
efêmero e morre no deploy. Na investigação daquele incidente só havia 2h de histórico porque o
contêiner tinha sido recriado — justamente a janela que interessava tinha sumido.

A janela de coleta (5 min) é maior que o intervalo do cron (5 min) de propósito, para não abrir
buraco entre ciclos. O custo é duplicata na fronteira, resolvida por `ON CONFLICT DO NOTHING`
sobre `(ocorrido_em, mensagem)`.

## O painel

Datasource novo no Grafana → banco `hub`, usuário dedicado com `SELECT` apenas no schema
`zoi_watchdog`. Não reusar o `grafana_ro` do `allwatcher`: bancos diferentes, permissões
diferentes.

Dashboard em kiosk, refresh 30s:

1. **Faixa superior** — contador de alertas ativos. Zero pinta verde; qualquer valor pinta a
   faixa inteira de vermelho. É o único elemento legível a três metros, e é o que a TV existe
   para mostrar.
2. **Alertas ativos** — assunto e `desde`, ordenado do mais velho para o mais novo. Mais velho
   primeiro porque alerta que dura é alerta que ninguém tratou.
3. **Grade de conexões** — 17 células, uma por número: rótulo, estado e idade do último inbound.
4. **Filas** — `wait` e `failed` das duas filas.
5. **Rodapé** — últimos erros `level >= 50`, pequeno. É referência, não o assunto da tela.

Um estado a mais que os cinco painéis: se o heartbeat estourar, tudo isso é substituído por
"watchdog parado há X min". Dado velho não pode ser exibido como se fosse atual.

## Acesso da TV

O Grafana está com anônimo desativado (`GF_AUTH_ANONYMOUS_ENABLED=false`) e não vou ligar isso
globalmente. Uma org `TV` com papel `Viewer` anônimo, contendo apenas este dashboard: a TV abre a
URL e nunca pede login, e nada mais do Grafana fica exposto.

A TV fica numa sala. Vale registrar o que aparece nela: nome de conexão, número de WhatsApp da
empresa cliente e contadores. Não aparece conteúdo de mensagem, nem telefone de cliente final,
nem dado pessoal. Isso é restrição de projeto dos painéis, não consequência acidental — o painel
5 mostra `msg` do log, e log de erro pode carregar telefone. Truncar e nunca exibir campo livre
de payload.

## Testes

O `zoi-watchdog.sh` não tem teste hoje, o que é parte do problema: os dois sinais que ficaram
cegos em produção (o `WRONGTYPE` do ZCARD, o segredo truncado) teriam morrido num teste.

`scripts/test-watchdog.sh`, sem framework, contra um Postgres descartável:

- conexão silenciosa com baseline acima do mínimo → ALERTA
- conexão silenciosa com baseline abaixo do mínimo → OK (o falso positivo que inutilizaria a checagem)
- conexão silenciosa fora da janela de horário → OK
- conexão recebendo normalmente → OK
- `desde` preservado quando o alerta se repete entre ciclos
- `desde` reiniciado quando volta a alertar depois de resolvido
- heartbeat gravado no fim, e ausente quando o script aborta no meio

As nove checagens antigas não são tocadas, então não regridem. Não vou escrever teste
retroativo para elas neste trabalho.

## Ordem de implantação

Cada passo é reversível e nenhum derruba o watchdog atual.

1. **Caminho de implantação do repositório para `/root/zoi-watchdog.sh`.** Um `install.sh` que
   copia, valida com `bash -n` e guarda a versão anterior. Vem primeiro porque sem ele todo
   passo seguinte precisa de edição manual no servidor — o hábito que criou a divergência.
2. Schema e usuário do Grafana (só cria; nada lê ainda)
3. `registrar()` no script, chamada dentro de `alertar()`/`resolvido()`. As nove checagens
   passam a gravar. E-mail intocado.
4. Heartbeat + poda de retenção
5. Checagens 10, 11 e 12, com os testes
6. Coleta de erro de log
7. Datasource, dashboard, org `TV`
8. Ligar a TV; ajustar limiares depois de duas semanas de dado real

O passo 3 sozinho já entrega valor: dá para consultar o estado do vigia, o que hoje não dá.

## Riscos

**O watchdog vira dependência do banco.** Se o Postgres do Hub cair, `registrar()` falha. O
script tem `set -uo pipefail` sem `-e` justamente para que uma checagem que falha não aborte as
outras, e `registrar()` precisa seguir a mesma regra: falha dela nunca pode impedir o e-mail.
E-mail é o canal que sobrevive ao banco; a gravação é o que enriquece, não o que substitui.

**Limiares errados na primeira aposta.** Os três novos são chutes informados. Errados para baixo
viram ruído e treinam todo mundo a ignorar a TV — que é como um painel morre. Por isso ficam num
bloco só, e por isso o passo 7 existe.

**Silêncio de inbound sazonal.** Feriado, fim de semana e recesso do cliente derrubam o baseline
e podem alertar. A janela de horário cobre a noite; não cobre feriado. Aceito por ora — o
antirruído de 6h limita o dano a poucos e-mails, e a alternativa (calendário de feriados) é
complexidade grande demais para o retorno.

## Onde mora o código

`raul-behnke/zapzoi-monitor`, repositório dedicado, clonado na VPS — que é onde o projeto inteiro
vive. O primeiro commit é `/root/zoi-watchdog.sh` verbatim.

A cópia em `zoi-hub-build/scripts/zoi-watchdog.sh` estava três versões atrás do que roda (sem
blue/green, sem a separação `wait`/`failed`, sem a checagem 9) e foi descartada. Escolher entre as
duas por diff seria escolher entre o que roda e o que alguém achou que rodava.

Enquanto o passo 1 não existir, editar o repositório não muda produção — o cron aponta para
`/root/zoi-watchdog.sh`. Fechar essa distância é o passo 1, e vem antes de qualquer checagem nova:
sem ele, todo trabalho aqui volta a divergir do servidor, que é o defeito que este repositório
existe para consertar.

## Questões em aberto

- Limiares das checagens 10-12: aprovados como padrão inicial, a revisar no passo 7.
