# CMC Hmg -> Prod GraphQL Plan

## Recap

The workspace follows a clean-architecture / DDD shape. CMC keeps backend, presentation, domain, and interfaces separated, with KISS and cohesion favored over over-splitting. Backend code uses multiple Prisma clients and NestJS. For docker, the current layout is:

- `cmc_dev` and `pnae_dev_default` for dev
- `cmc_hmg` and `pnae_hmg_default` for hmg
- `cmc_prod` and `pnae_prod_default` for prod
- nginx exposes them on ports `3001`, `3002`, and `3003`

The GraphQL server is the bridge app in each environment. It joins the CMC and PNAE network for that same environment, so both apps can reach the legacy DB through one API.

## Goal

Keep the current hmg environment mostly intact, but make CMC backend hmg talk to the **prod GraphQL API** with the smallest safe change set. Do not touch prod nginx. If any Docker wiring change is needed, prefer attaching the prod GraphQL container to the hmg-facing CMC network rather than attaching hmg services to a prod network. Keep the Phase 2 sync feature, but scope it to the hmg environment.

## Phase 1: hmg Backend -> Prod GraphQL

### 1) Keep the current hmg network model

Do not rename the current hmg network or the current nginx setup. The simplest approach is to leave `cmc_hmg` and `nginx_hmg` as they are and avoid giving hmg containers direct membership in a prod network.

### 2) Attach the prod GraphQL container to the hmg-facing CMC network

Update `/home/apps/emater_graphql_server/docker-compose.prod.yaml` so `graphql_server_prod` joins:

- `cmc_prod` as it already does
- `cmc_hmg` as an extra external network

That lets `cmc_backend_hmg` resolve `graphql_server_prod:4200` through `cmc_hmg` without making the hmg backend a member of a prod-only network. This keeps the hmg side cleaner and better matches the intent of environment isolation.

### 3) Point the hmg backend GraphQL URL to prod

Update `/home/apps/cmc/.env.staging` so the backend uses:

- `GRAPHQL_SERVER_URL='http://graphql_server_prod:4200'`

Keep the rest of the hmg DB settings as they are, because this change is only about the GraphQL bridge target.

### 4) Leave nginx alone unless a config mismatch appears

If `cmc_backend_hmg` keeps the same service name and port, `nginx.hmg.conf` should not need changes. The nginx layer already routes to the hmg backend, and the backend itself will handle the new GraphQL destination through its env + network wiring.

## Phase 2: Prod -> hmg Certificacao Sync

Keep the sync feature, but scope it to the current hmg backend.

### Sync scope

Only sync these certificacao models:

- `Relatorio`
- `Avaliacao`
- `Certificado`

Ignore the rest of the schema (`Grupo`, `Subgrupo`, `Norma`, `Recomendacao`, `Curso`).

### KISS approach

Add a small NestJS sync module inside the backend, with a second Prisma client pointing at the prod certificacao database.

- Use the existing certificacao Prisma client pattern already used by CMC
- Add a prod Prisma client only for the sync path
- Compare by `id` and `updatedAt` first
- Filter out rows that already match before any upsert
- Upsert only rows that are new or changed
- Keep the endpoint available only from hmg

### Endpoint behavior

Expose one internal controller endpoint from the backend, guarded so it only works in the hmg environment:

- `GET /system/sync/certificacao`
- `NODE_ENV === 'staging'` guard, or equivalent hmg-only guard already used by the backend
- No request body
- Hitting the endpoint triggers the backend to fetch from the prod Prisma client and upsert into the hmg Prisma client
- Return a small summary of inserted and updated rows

### Sync method

Keep the sync logic deliberately simple:

**Relatorio and Certificado** (both have `updatedAt`):

1. Read only `id` and `updatedAt` from hmg for the model.
2. Read only `id` and `updatedAt` from prod for the same model.
3. Build a fast lookup map from the hmg rows.
4. Filter the prod rows into two groups:
   - rows whose `id` is missing in hmg → new
   - rows where `prod.updatedAt > hmg.updatedAt` → changed
5. Ignore all other rows (same `id`, same or older `updatedAt`).
6. Fetch full records from prod only for the filtered set.
7. Upsert those records into hmg.

> Use `prod.updatedAt > hmg.updatedAt`, not `!==`. A not-equal check would overwrite hmg rows that are somehow ahead of prod, which is undesirable.

**Avaliacao** (no `updatedAt`, tied to Relatorio):

`Avaliacao` has no `updatedAt` column, but it belongs to `Relatorio` via `relatorioId`. Its sync is fully driven by the Relatorio diff already computed above — no separate comparison pass is needed.

For each Relatorio in the **new** or **changed** set:
1. Delete all Avaliacoes for that `relatorioId` from hmg.
2. Fetch all Avaliacoes for that `relatorioId` from prod.
3. Insert them into hmg.

This delete-and-reinsert approach handles additions, updates, and deletions in one pass. A pure upsert would silently leave stale Avaliacoes behind if a norma was removed from a relatorio in prod.

For Relatorios that are unchanged, skip their Avaliacoes entirely.

This is not meant to be perfect replication logic. It is meant to be a practical KISS sync trigger that avoids unnecessary writes.

### Sync order

Sync in dependency order:

1. `Relatorio` — diff by `id` and `updatedAt`, upsert changed/new rows
2. `Avaliacao` — driven by step 1; delete + re-insert per changed/new Relatorio
3. `Certificado` — diff by `id` and `updatedAt`, upsert changed/new rows

That keeps foreign-key relationships safe and avoids unnecessary complexity.

## Relevant Files

### Modify

- `/home/apps/emater_graphql_server/docker-compose.prod.yaml` - add `cmc_hmg` network to `graphql_server_prod`
- `/home/apps/cmc/.env.staging` - change `GRAPHQL_SERVER_URL` to `graphql_server_prod:4200`; add `PROD_DATABASE_URL` pointing at the prod certificacao Postgres (required for the prod Prisma client in Phase 2)
- `/home/apps/cmc/backend/src/app.module.ts` - register the sync module
- `/home/apps/cmc/backend/src/system/sync/*` - new sync module files

### Maybe modify if needed

- `/home/apps/nginx/nginx.hmg.conf` - only if the backend service name or port changes, which is not expected in this simplified plan

### Reference

- `/home/apps/cmc/docs/app-overview-and-coding-guidelines.md`
- `/home/apps/nginx/docs/current-docker-networks.md`
- `/home/apps/cmc/backend/src/shared/prisma/certificacao/prisma.service.ts`
- `/home/apps/cmc/backend/prisma/certificacao/schema/public.prisma`

## Verification

1. Run `docker compose -f /home/apps/emater_graphql_server/docker-compose.prod.yaml config` and confirm `graphql_server_prod` is attached to both `cmc_prod` and `cmc_hmg`.
2. Confirm `cmc_backend_hmg` can resolve `graphql_server_prod` from inside the container while remaining only on the hmg-side network wiring it already uses.
3. Confirm `nginx_hmg` still routes to the hmg backend on port `3002`.
4. Hit `GET /system/sync/certificacao` only from hmg and confirm it returns a summary.
5. Confirm prod nginx was not changed.

## Decisions

- Keep the current hmg naming and layout. Renaming it to staging would create extra churn for little benefit.
- Prefer attaching `graphql_server_prod` to `cmc_hmg` over attaching `cmc_backend_hmg` to `cmc_prod`. The hmg environment should not need to join a prod network just to consume one upstream service.
- Keep the sync feature in the backend. The backend already owns Prisma, dotenv, and NestJS plumbing, so this is the most direct and maintainable place for it.
- Keep the current env-grouped network model and nginx port split. It is already clear and isolated enough, so there is no reason to redesign it for this change.
- Use a `GET` endpoint because the client is not sending sync payload data. The request only triggers a server-side fetch and sync operation.
- Do not expand the sync scope beyond the three certificacao models. The KISS version should stay focused and avoid turning into a general-purpose replication system.
