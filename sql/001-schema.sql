-- Schema do vigia. Roda no Postgres DO HOST (16.15), onde o allwatcher já mora — e não dentro do
-- hub_postgres.
--
-- A escolha é a restrição do projeto, não conveniência: nada da estrutura do provedor pode ser
-- tocado. O banco do Hub é só LIDO, pelo mesmo `docker exec` que o watchdog já usa hoje. Aqui
-- nada do Hub é criado, alterado ou migrado, e o `prisma migrate deploy` nunca vê este arquivo.
--
-- O Grafana roda em rede host e alcança 127.0.0.1:5432 — caminho já provado pelo datasource do
-- allwatcher. O hub_postgres não publica porta nenhuma, então ele não seria alcançável daqui de
-- todo modo.
--
-- Aplicar (o 000 cria o banco e o papel):
--   sudo -u postgres psql -f sql/000-bootstrap.sql
--   sudo -u postgres psql -d watchdog -f sql/001-schema.sql
--
-- Este arquivo NÃO escolhe banco — nem `CREATE DATABASE`, nem `\connect`. Quem escolhe é o `-d` de
-- quem chama, e é isso que deixa o test-watchdog.sh aplicá-lo num banco descartável. Quando o
-- `\connect watchdog` morava aqui, o teste criava um banco de teste e mandava as tabelas para
-- produção sem dizer nada.
--
-- Idempotente: pode rodar de novo sem quebrar nada.

\set ON_ERROR_STOP on

-- Estado atual de cada checagem. Uma linha por chave — não cresce.
--
-- As chaves são as MESMAS que alertar()/resolvido() já usam no script ('api-fora', 'disco',
-- 'sessao-<id>', 'fila-<nome>-<estado>'...). Reaproveitar em vez de inventar um identificador
-- novo é o que faz as nove checagens existentes alimentarem a tela sem que nenhuma seja tocada.
CREATE TABLE IF NOT EXISTS estado (
  chave      text PRIMARY KEY,
  estado     text NOT NULL CHECK (estado IN ('ALERTA', 'OK')),
  assunto    text NOT NULL,
  corpo      text NOT NULL,
  -- Quando ENTROU no estado atual. Não se mexe enquanto o estado não muda: é o que responde "há
  -- quanto tempo", que o e-mail nunca soube responder. Alerta de 4 horas e alerta de 4 minutos
  -- pedem reações diferentes.
  desde      timestamptz NOT NULL,
  medido_em  timestamptz NOT NULL
);

-- Erros do log da API, para o painel de rodapé.
--
-- Existe porque `docker logs` é efêmero e morre no deploy. No diagnóstico de 2026-09-05 só havia
-- 2h de histórico porque o contêiner tinha sido recriado — justamente a janela que interessava.
-- Guarda `msg` e nível, e NÃO o payload da linha. A TV fica numa sala: log de erro do Hub carrega
-- telefone de cliente final, e o que não é gravado não vaza pela parede. Para depurar de verdade
-- existe o `hub-logs`, que fala com o contêiner e não com esta tabela.
CREATE TABLE IF NOT EXISTS erro (
  id           bigserial PRIMARY KEY,
  ocorrido_em  timestamptz NOT NULL,
  nivel        int NOT NULL,
  mensagem     text NOT NULL
);
ALTER TABLE erro DROP COLUMN IF EXISTS bruto;

-- A janela de coleta (5 min) é do tamanho do intervalo do cron, para não abrir buraco entre
-- ciclos. O custo é duplicata na fronteira, e é este índice que a desfaz.
CREATE UNIQUE INDEX IF NOT EXISTS erro_dedup ON erro (ocorrido_em, md5(mensagem));
CREATE INDEX IF NOT EXISTS erro_recente ON erro (ocorrido_em DESC);

-- Heartbeat. O watchdog não consegue vigiar a si mesmo; o Grafana consegue.
--
-- Sem isto, cron morto deixa a última foto no lugar e a TV fica verde com dado velho — pior que
-- TV apagada, porque afirma saúde em vez de admitir ignorância. O painel pinta tudo de vermelho
-- se max(rodou_em) passar de 12 minutos.
--
-- Gravado na ÚLTIMA linha do script, nunca na primeira: no começo, diria "rodou" para um ciclo
-- que abortou na terceira checagem.
CREATE TABLE IF NOT EXISTS execucao (
  id        bigserial PRIMARY KEY,
  rodou_em  timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS execucao_recente ON execucao (rodou_em DESC);

-- Foto das conexões a cada ciclo, para a grade do painel.
--
-- Copiada para cá, e não lida do banco do Hub na hora: assim o Grafana nunca abre conexão com o
-- provedor. Um datasource só, e a leitura do Hub continua acontecendo apenas dentro do script,
-- pelo caminho que já existia.
CREATE TABLE IF NOT EXISTS conexao_snapshot (
  connection_id     text PRIMARY KEY,
  rotulo            text,
  numero            text,
  status            text NOT NULL,
  ultimo_inbound_em timestamptz,
  medido_em         timestamptz NOT NULL
);

-- Leitura para o painel.
--
-- Condicional porque o banco descartável do teste roda sem o 000, e um GRANT para papel que não
-- existe abortaria o schema inteiro — o teste morreria antes da primeira asserção.
--
-- Só SELECT, e isso é dito de propósito: um painel numa parede não escreve em lugar nenhum, e a
-- única forma de garantir isso é não conceder o direito.
DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'grafana_tv') THEN
    EXECUTE 'GRANT USAGE ON SCHEMA public TO grafana_tv';
    EXECUTE 'REVOKE ALL ON ALL TABLES IN SCHEMA public FROM grafana_tv';
    EXECUTE 'GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_tv';
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO grafana_tv';
  END IF;
END
$$;
