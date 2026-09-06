-- Cria o banco e o papel de leitura. Roda UMA vez, conectado a qualquer banco:
--
--   sudo -u postgres psql -f sql/000-bootstrap.sql
--
-- Separado do 001 porque `CREATE DATABASE` e `\connect` amarram o arquivo a um banco específico, e
-- o 001 precisa ser aplicável a qualquer um. Enquanto estavam juntos, o test-watchdog.sh criava um
-- banco descartável, mandava o schema para ele — e o `\connect watchdog` levava as tabelas para
-- produção. O teste passava a medir o banco errado, que é a única coisa pior que não ter teste.
--
-- Idempotente.

\set ON_ERROR_STOP on

SELECT 'CREATE DATABASE watchdog'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'watchdog')\gexec

-- Papel de leitura do painel.
--
-- Separado do grafana_ro do allwatcher de propósito: bancos diferentes, permissões diferentes, e
-- uma credencial que vaza não deve levar as duas junto.
--
-- A senha real NÃO mora neste arquivo. Depois de aplicar:
--   sudo -u postgres psql -c "ALTER ROLE grafana_tv PASSWORD '<senha>'"
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'grafana_tv') THEN
    CREATE ROLE grafana_tv LOGIN PASSWORD 'trocar-me';
  END IF;
END
$$;

GRANT CONNECT ON DATABASE watchdog TO grafana_tv;
