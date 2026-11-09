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

The agent workflow uses the community node `@tavily/n8n-nodes-tavily` for web search.
Install it before importing: n8n → *Settings* → *Community nodes* → *Install*. After import,
create the credentials (Telegram, Anthropic, Postgres, Tavily) and select them in the nodes.

Message types: text goes straight to the agent, photos are downloaded and passed to Claude as
images, voice messages are transcribed by Groq Whisper (*Transcribe voice* node). For voice, create
a free key at https://console.groq.com and a **Header Auth** credential in n8n
(name `Authorization`, value `Bearer <key>`), then select it in the *Transcribe voice* node.
Anything else (stickers, documents) gets a short "not supported yet" reply from the agent.

Long-term memory: facts about the owner live in the `jarvis_facts` table
(`config/postgres/init.sql`, applied by `start.ps1`). *Load facts* puts them into the system prompt
on every message; the agent adds and removes them with the *Save fact* / *Forget fact* tools.
See what it remembers: `docker compose exec postgres psql -U jarvis -d jarvis -c "SELECT * FROM jarvis_facts"`.

Replies show a "typing..." status while the agent works, are split into several messages when
longer than Telegram allows, and support **bold**, `code` and links (sent as Telegram HTML).

Google tools: the agent can list and create events in the primary Google Calendar, search and read
Gmail, and create Gmail **drafts**. It cannot send, delete or move emails, or change or delete
events. Setup: a Google Cloud project with the Gmail and Google Calendar APIs enabled, an OAuth
consent screen with your account as a test user (or published), and a Web OAuth client with the
redirect URI `http://localhost:5678/rest/oauth2-credential/callback`. In n8n, create the
*Google Calendar OAuth2 API* and *Gmail OAuth2 API* credentials with that client and select them
in the tool nodes. In Testing mode Google expires the sign-in after 7 days; reconnect with
*Sign in with Google* in the credential.

Set `TIMEZONE` in `.env` to your own timezone: event times and the date in the prompt use it.

Errors in the *Jarvis* workflow trigger *Jarvis error notifier*, which sends the failing node and
error message to the owner in Telegram.

Keep **Thinking Mode = Disabled** in the Anthropic Chat Model node. Claude's thinking blocks are
signed for the exact conversation they were created in; the chat memory keeps a sliding window,
so stored thinking blocks become invalid and the API returns 400 "Invalid signature in thinking block".

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
