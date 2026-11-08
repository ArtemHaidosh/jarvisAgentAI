# Troubleshooting

Start with `.\scripts\status.ps1`: it checks the chain Docker → n8n → ngrok → Telegram
and shows where it breaks.

## Docker

**"Docker is installed but not running"**: open Docker Desktop and wait for
*Engine running*.

**Port 5678 or 4040 is busy**: another n8n or ngrok is already running.
Find the process: `netstat -ano | findstr :5678`.

## n8n

**n8n won't start, logs say `Mismatching encryption keys`**: `N8N_ENCRYPTION_KEY` in `.env`
changed after the first start. Restore the old value. If it's lost and the data doesn't
matter, delete the volume: `docker compose down -v` (all workflows will be lost).

Logs: `docker compose logs -f n8n`

## ngrok

**`ERR_NGROK_4018` / authentication failed**: wrong `NGROK_AUTHTOKEN`.

**`ERR_NGROK_108` / session already active**: a free account allows one agent session.
Close ngrok running elsewhere (another terminal, another machine).

**Domain not found / not yours**: check `NGROK_DOMAIN` in `.env`. It must exactly match
https://dashboard.ngrok.com/domains, without `https://`.

**Traffic policy error**: ngrok rejected `config/ngrok-policy.yml`. Check
`docker compose logs ngrok`; it points to the offending line.

Logs: `docker compose logs -f ngrok`. Every incoming request is visible at http://localhost:4040

## Telegram

**Bot is silent, `status.ps1` says the webhook is not set**: the workflow with the Telegram
Trigger is not active. Toggle *Active* in n8n.

**Webhook points to `/webhook-test/...`**: you tested the node with *Listen for test event*.
Toggle *Active* off and on again.

**"Last delivery error"**: Telegram couldn't reach your domain, usually because the computer
was asleep or `start.ps1` wasn't running. Telegram retries on its own once the tunnel is back.
`pending_update_count` shows how many updates are queued.

**Telegram allows only one webhook per bot.** If the same token is used by another service,
they will keep overwriting each other's webhook.
