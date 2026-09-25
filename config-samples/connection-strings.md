# Cheat sheet: connection strings for the local infrastructure

All values match the defaults in `local-infra/.env`. The SQL `sa` password is in gitignored `.env.local` (see `.env.local.example`).

| Service | Connection string / address | UI |
|---|---|---|
| RabbitMQ | `host=localhost;username=guest;password=guest` (NServiceBus) | http://localhost:15672 |
| RabbitMQ (AMQP) | `amqp://guest:guest@localhost:5672/` | — |
| Redis | `localhost:6379,allowAdmin=true` | — |
| SQL Server (admin) | `Server=localhost,1433;User Id=sa;Password=<MSSQL_SA_PASSWORD from .env.local>;TrustServerCertificate=True` | SSMS |
| SQL Server (apps) | `...User Id=EuroWebsite;Password=pensandpencils;...` | — |
| SQL Server (NServiceBus) | `...User Id=EuroService;Password=0*lEVEL*gIVES?;...` | — |
| SMTP (Mailpit) | `localhost:1025`, no auth, no TLS | http://localhost:8025 |
| Elasticsearch | `http://localhost:9200` | Kibana: http://localhost:5601 |

The two application logins are not choices. Every environment's stored
configuration carries these exact credentials, and a restored support centre
brings them along, so the local server has to match — see
[`../sql/init/00-login-and-databases.sql`](../sql/init/00-login-and-databases.sql).
Only `sa` is ours — set it in `.env.local` (see `.env.local.example`).

## One name, both sides

Run [`../hosts-setup.ps1`](../hosts-setup.ps1) once (elevated). It maps
`mssql`, `rabbit`, `redis`, `mailpit`, `config-api` and `elastic` to `127.0.0.1`
in the Windows hosts file.

After that a single configuration value works everywhere:

| From | `mssql,1433` resolves to |
|---|---|
| a Noodles container | the `mssql` container over the `hostnet` network |
| a Power site under IIS on this machine | `127.0.0.1:1433`, the published port |

This matters because Power is .NET Framework 4.7.2 under IIS and can never move
into a container, while the Noodles services now do. They share one
`cfg_Configurations` table, so the value has to be valid from both sides.

Container names match service names, so the same name also works for
`docker exec` and for container-to-container DNS.

## Container to an app running on the Windows host

Use `host.docker.internal` — e.g. the Configuration API running on the host is
`http://host.docker.internal:8080/Configuration`.
