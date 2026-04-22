# Current Docker Networks & Application Wiring

## Overview

The server at `/home/apps/` hosts 3 applications and a reverse proxy, each running in 3 parallel environments: **dev**, **hmg** (homolog/staging), and **prod**. Each environment has its own isolated Docker network, and a dedicated nginx instance exposed on a different external port.

| Env  | Nginx external port | Docker networks                 |
| ---- | ------------------- | ------------------------------- |
| dev  | 3001                | `cmc_dev`, `pnae_dev_default`   |
| hmg  | 3002                | `cmc_hmg`, `pnae_hmg_default`   |
| prod | 3003                | `cmc_prod`, `pnae_prod_default` |

All networks are **external** (pre-created) and referenced by each docker-compose file.

---

## Applications

| App                       | Path                               | Role                                                       |
| ------------------------- | ---------------------------------- | ---------------------------------------------------------- |
| **emater_graphql_server** | `/home/apps/emater_graphql_server` | GraphQL API bridge to the company's legacy DB (DEMETER)    |
| **CMC**                   | `/home/apps/cmc`                   | Fullstack monorepo (NestJS backend + NextJS frontend)      |
| **PNAE**                  | `/home/apps/pnae`                  | Mobile app backend + fullstack web interface (Nest+NextJS) |
| **nginx**                 | `/home/apps/nginx`                 | Reverse proxy exposing all apps to the web via HTTPS       |

---

## Docker Networks in Detail

### `cmc_dev` (external)

| Container            | App/Service        | Internal port |
| -------------------- | ------------------ | ------------- |
| `cmc_backend_dev`    | CMC NestJS backend | 3000          |
| `graphql_server_dev` | GraphQL API bridge | 4000          |
| `nginx_dev`          | Reverse proxy      | 443           |

### `pnae_dev_default` (external)

| Container            | App/Service         | Internal port |
| -------------------- | ------------------- | ------------- |
| `pnae_backend_dev`   | PNAE NestJS backend | 3000          |
| `redis_dev`          | Redis cache         | 6379          |
| `graphql_server_dev` | GraphQL API bridge  | 4000          |
| `nginx_dev`          | Reverse proxy       | 443           |

### `cmc_hmg` (external)

| Container             | App/Service               | Internal port      |
| --------------------- | ------------------------- | ------------------ |
| `cmc_backend_hmg`     | CMC NestJS backend        | 3000               |
| `cmc_postgres_hmg`    | PostgreSQL (certificacao) | 5432 (→ host 5532) |
| `postgres_gestao_hmg` | PostGIS (gestao)          | 5432 (→ host 5542) |
| `graphql_server_hmg`  | GraphQL API bridge        | 4100               |
| `nginx_hmg`           | Reverse proxy             | 443                |

### `pnae_hmg_default` (external)

| Container            | App/Service         | Internal port      |
| -------------------- | ------------------- | ------------------ |
| `pnae_backend_hmg`   | PNAE NestJS backend | 3100               |
| `postgres_pnae_hmg`  | PostgreSQL (PNAE)   | 5432 (→ host 5434) |
| `redis_hmg`          | Redis cache         | 6379               |
| `graphql_server_hmg` | GraphQL API bridge  | 4100               |
| `nginx_hmg`          | Reverse proxy       | 443                |

### `cmc_prod` (external)

| Container             | App/Service                      | Internal port      |
| --------------------- | -------------------------------- | ------------------ |
| `cmc_backend_prod`    | CMC NestJS backend               | 3000               |
| `cmc_postgres_prod`   | PostgreSQL (certificacao)        | 5432 (→ host 5533) |
| `graphql_server_prod` | GraphQL API bridge (×3 replicas) | 4200               |
| `nginx_prod`          | Reverse proxy                    | 443                |

### `pnae_prod_default` (external)

| Container             | App/Service                       | Internal port      |
| --------------------- | --------------------------------- | ------------------ |
| `pnae_backend_prod`   | PNAE NestJS backend (×3 replicas) | 3200               |
| `postgres_pnae_prod`  | PostgreSQL (PNAE)                 | 5432 (→ host 5435) |
| `redis_prod`          | Redis cache                       | 6399               |
| `graphql_server_prod` | GraphQL API bridge (×3 replicas)  | 4200               |
| `nginx_prod`          | Reverse proxy                     | 443                |

---

## GraphQL Server as a Network Bridge

The GraphQL server is the key cross-app connector. Each env instance joins **two** Docker networks (one CMC, one PNAE), allowing both apps to reach the GraphQL API without exposing it outside Docker.

```
┌─────────────────────┐     ┌─────────────────────┐
│    cmc_dev network   │     │ pnae_dev_default net │
│                      │     │                      │
│  cmc_backend_dev ──┐ │     │ ┌── pnae_backend_dev │
│                    │ │     │ │                    │
│         graphql_server_dev (on both networks)     │
│                      │     │                      │
│  nginx_dev ──────────┼─────┼────── nginx_dev      │
└─────────────────────┘     └─────────────────────┘
```

| Container             | Networks                        | Internal port | Legacy DB    |
| --------------------- | ------------------------------- | ------------- | ------------ |
| `graphql_server_dev`  | `cmc_dev`, `pnae_dev_default`   | 4000          | DEMETER_HMG  |
| `graphql_server_hmg`  | `cmc_hmg`, `pnae_hmg_default`   | 4100          | DEMETER_HMG  |
| `graphql_server_prod` | `cmc_prod`, `pnae_prod_default` | 4200          | DEMETER_PROD |

> Dev and hmg GraphQL containers both connect to the same `DEMETER_HMG` legacy database. Prod connects to `DEMETER_PROD`.

---

## Nginx Routing

Each nginx instance sits on both the CMC and PNAE networks for its environment, acting as the single HTTPS entry point.

### `nginx.dev.conf` — port 3001

| Route          | Upstream                      |
| -------------- | ----------------------------- |
| `/gateway-api` | `graphql_server_dev:4000`     |
| `/pnae`        | `pnae_backend_dev:3000`       |
| `/cmc/web`     | Maintenance page (not active) |

### `nginx.hmg.conf` — port 3002

| Route          | Upstream                                                                         |
| -------------- | -------------------------------------------------------------------------------- |
| `/gateway-api` | `graphql_server_hmg:4100`                                                        |
| `/pnae`        | `pnae_backend_hmg:3100`                                                          |
| `/cmc/web`     | `cmc_frontend_hmg:3000`                                                          |
| `/cmc_backend` | `cmc_backend_hmg:3000` (via `nginx.cmc-backend.conf` include, with tile caching) |

### `nginx.prod.conf` — port 3003

| Route          | Upstream                                                                         |
| -------------- | -------------------------------------------------------------------------------- |
| `/gateway-api` | `graphql_server_prod:4200`                                                       |
| `/pnae`        | `pnae_backend_prod:3200`                                                         |
| `/cmc/web`     | Static NextJS build (served directly by nginx)                                   |
| `/cmc_backend` | `cmc_backend_prod:3000` (via `nginx.cmc-backend.conf` + `nginx.cmc-static.conf`) |

---

## Startup Scripts

All apps are started via `/home/apps/scripts/start_apps.sh`, which calls in order:

1. `start_graphql_server.sh` — loops through `dev`, `hmg`, `prod` docker-compose files
2. `start_pnae.sh` — loops through `dev`, `hmg`, `prod` docker-compose files
3. `start_nginx.sh` — starts all three nginx docker-compose files

Each script iterates all three environments and runs `docker compose -f <file> up -d`.

---

## Key Design Notes

- **Environment isolation**: Each env is fully isolated in its own network. Containers can only talk to other containers on the same network.
- **Nginx per-env port**: dev=3001, hmg=3002, prod=3003. All use HTTPS (SSL certs shared via volume mount).
- **GraphQL bridge pattern**: The GraphQL server is the only container that spans two networks per env, bridging CMC and PNAE without direct cross-app communication.
- **External networks**: All networks are declared `external: true` — they must be pre-created with `docker network create <name>` before first startup.
- **No cross-env communication** (by default): dev containers cannot see hmg or prod, and vice versa. The planned staging change (see `environment_changes_plan.md`) is the first intentional cross-env bridge — staging CMC joins `cmc_prod` network to reach the prod GraphQL API.
