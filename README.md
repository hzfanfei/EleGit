# EleGit · 问象

问象 is a Flutter phone app plus a local companion server. Ask about GitHub repo progress from your phone; this computer answers using GitHub data and the local Cursor environment.

The product plan lives in the Project store, not in this repo:

`/cursor/stores/bc-d0755f26-a3ad-4de8-b86a-7c66b6eb5ff3/docs/wenxiang-plan.md`

## Run the companion server

```bash
cd server
npm install
npm start
```

Listens on `0.0.0.0:8787`. The first start prints an API key and LAN URLs. Config (including the GitHub token) is stored in `~/.wenxiang/config.json`.

Optional env vars: see `server/.env.example`.

## Reach the phone

- Same Wi-Fi: in 问象, set the server URL to a printed LAN address (`http://<pc-ip>:8787`) and paste the API key.
- Off-LAN: install [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/), then start a tunnel (`POST /v1/tunnel/start` or the in-app button) and paste the `https://*.trycloudflare.com` URL. A custom frp/ngrok command can be set in `~/.wenxiang/config.json` under `tunnel.customCommand` (`{port}` is replaced).

The phone talks only to this API.

## Run the Flutter app

```bash
cd app
flutter pub get
flutter run
```

On a physical phone, do not use `localhost` — that is the phone itself. Use the PC LAN IP or the tunnel URL.

GitHub login is **browser OAuth**. Create an OAuth App and set the Authorization callback URL to `{phone-base-url}/oauth/github/callback` (add LAN, `127.0.0.1`, and tunnel host as needed). Then copy `server/.env.example` to `server/.env` on that computer and fill `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET`. Do not commit `.env`. Process env wins over `.env`, which wins over `~/.wenxiang/config.json`.

Selected repos are cloned to `~/问象/<owner>/<repo>`. PAT remains a fallback only.

## Tests

```bash
cd server && npm test
```
