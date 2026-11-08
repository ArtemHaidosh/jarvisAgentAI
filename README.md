# Jarvis Agent: local infrastructure

A minimal environment for a learning AI agent: **n8n** runs on your machine, and a
**Telegram bot** delivers messages to it through an **ngrok** tunnel. Everything is free.

```
Telegram ──HTTPS──► ngrok (your-domain.ngrok-free.app) ──► n8n (localhost:5678, Docker)
                     only /webhook/* is let through           your workflow
```

## One-time prerequisites

1. **Docker Desktop**: https://www.docker.com/products/docker-desktop/ (install and start it).
2. **Telegram bot**: message [@BotFather](https://t.me/BotFather) → `/newbot` → copy the token.
3. **ngrok** (free account): https://dashboard.ngrok.com/signup
   - **Authtoken**: *Your Authtoken* section;
   - **static domain**: *Domains* → *New Domain* (one is free).

## Running

Open PowerShell in the project folder:

```powershell
.\scripts\setup.ps1      # once: creates .env and asks for the tokens
.\scripts\start.ps1      # starts n8n + ngrok
.\scripts\status.ps1     # shows what works and what doesn't
.\scripts\stop.ps1       # stops everything (your workflows are kept)
```

If PowerShell says running scripts is disabled, run this once:
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`

After `start.ps1`:

| What | Address |
|---|---|
| n8n editor | http://localhost:5678 |
| ngrok request inspector (shows every request from Telegram) | http://localhost:4040 |
| Public webhooks | `https://<NGROK_DOMAIN>/webhook/...` |

On first open, n8n asks you to create an owner account. It is local only.

## Connecting the bot in n8n

1. Create a workflow in n8n and add a **Telegram Trigger** node.
2. Create a **Telegram API** credential and paste the bot token.
3. Toggle **Active** (top right). n8n registers the webhook with Telegram on your domain.
4. Message the bot, then check `.\scripts\status.ps1` and the *Executions* tab in n8n.

> *Listen for test event* temporarily switches the bot's webhook to a test URL.
> When you're done testing, toggle the workflow off and on again to restore the production URL.

## Postgres (agent memory)

A Postgres container stores the agent's data, e.g. chat history for the
**Postgres Chat Memory** node. It has no published ports: only n8n can reach it.
Credential settings in n8n:

| Field | Value |
|---|---|
| Host | `postgres` |
| Database | `jarvis` |
| User | `jarvis` |
| Password | `POSTGRES_PASSWORD` from `.env` |
| Port | `5432` |
| SSL | `Disable` |

SQL console: `docker compose exec postgres psql -U jarvis -d jarvis`

## Workflows in git

Workflows live inside n8n (Docker volume). To keep them in the repo:

```powershell
.\scripts\export-workflows.ps1   # n8n -> workflows\*.json
.\scripts\import-workflows.ps1   # workflows\*.json -> n8n (restore / new machine)
```

The export keeps only nodes, connections and settings. It drops owner name/e-mail,
pinned test data and execution state, and refuses to finish if any value from `.env`
(owner ID, domain, tokens, passwords) is found in a workflow. Credentials are referenced
by id only; their secrets stay in n8n.

Put private values into workflows as expressions, not literals, e.g. the owner filter:
`{{ $env.TELEGRAM_OWNER_ID }}`.

## Tests

```powershell
.\tests\run-tests.ps1          # configs, .gitignore, no secrets in git (Docker need not run)
.\tests\run-tests.ps1 -Smoke   # plus the live system: n8n, tunnel, Telegram webhook
```

## Secrets

- All secrets live only in `.env`, which git ignores. The repo contains just the `.env.example` template.
- `N8N_ENCRYPTION_KEY` encrypts credentials inside n8n. **Do not change it** after the first start.
- The n8n editor is reachable only from your machine: ports are bound to `127.0.0.1`, and ngrok
  lets only `/webhook/*` through from the internet (see `config/ngrok-policy.yml`).

## Layout

```
docker-compose.yml        n8n + Postgres + ngrok
config/ngrok-policy.yml   what ngrok lets in from the internet
.env.example              settings template (no secrets)
scripts/                  setup / start / stop / status / export- and import-workflows
workflows/                exported n8n workflows
tests/run-tests.ps1       checks
docs/troubleshooting.md   common problems
```

n8n data is stored in the Docker volume `jarvis_n8n_data`, the database in `jarvis_postgres_data`.
`docker compose down -v` **deletes** both, together with all workflows and the agent's memory.
