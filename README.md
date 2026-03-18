<p align="center">
  <img src="assets/icon.png" alt="tunnel-cloud" width="160" />
</p>

<h1 align="center">tunnel-cloud</h1>

<p align="center">
  <strong>Hassle-free CLI to expose local dev servers via <a href="https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/">Cloudflare Tunnels</a> with stable, named subdomains on your own domain.</strong>
</p>

<p align="center">
  Like ngrok, but free — with SSL, no signup, and optional custom domains.
</p>

<p align="center">
  <a href="https://www.npmjs.com/package/tunnel-cloud"><img src="https://img.shields.io/npm/v/tunnel-cloud?color=F6821F&label=npm" alt="npm version" /></a>
  <a href="https://github.com/numanaral/tunnel-cloud/blob/main/LICENSE"><img src="https://img.shields.io/github/license/numanaral/tunnel-cloud?color=F6821F" alt="license" /></a>
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows%20(WSL)-1B1B1B" alt="platform" />
</p>

---

## Prerequisites

- **macOS**, **Linux**, or **Windows** via [WSL](https://learn.microsoft.com/en-us/windows/wsl/)
- [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/) — auto-installed if missing (prompts before installing)
- *(Optional)* A domain managed by Cloudflare DNS — only needed for stable subdomains

## Quick Start

**Instant** — no account, no config:

```bash
npx tunnel-cloud start
```

You get a random `https://<id>.trycloudflare.com` URL. Done.

**With your own domain** — stable, named subdomain:

```bash
npx tunnel-cloud start --domain yourdomain.com
```

First run will:
1. Install `cloudflared` if missing (prompts first)
2. Validate your dev server is running and reachable
3. Open your browser to authenticate with Cloudflare (one-time)
4. Create a named tunnel
5. Set up a DNS CNAME record
6. Start serving

Your app is now live at `https://tunnel-<project>.yourdomain.com`.

---

## Usage

```bash
tunnel-cloud <command> [options]
```

### Commands

| Command   | Description                                  |
|-----------|----------------------------------------------|
| `start`   | Create tunnel (if needed) and start serving  |
| `stop`    | Stop the running tunnel                      |
| `status`  | Check if the tunnel is running               |
| `logs`    | Tail the tunnel log                          |
| `cleanup` | Stop, delete tunnel and DNS route entirely   |

### Options

| Option                | Description                                              | Default              |
|-----------------------|----------------------------------------------------------|----------------------|
| `--domain <domain>`   | Cloudflare domain (omit for a random trycloudflare.com URL) | —                    |
| `--name <name>`       | Tunnel name                                              | Current directory name |
| `--origin <url>`      | Local URL to tunnel                                      | Auto-detect from running server |
| `--prefix <prefix>`   | Subdomain prefix                                         | `tunnel`             |
| `--protocol <proto>`  | cloudflared protocol                                     | `http2`              |
| `--no-watch`          | Disable auto-restart on tunnel process death              | Watch enabled        |

### Environment Variables

All options can be set via environment variables: `TUNNEL_DOMAIN`, `TUNNEL_NAME`, `TUNNEL_ORIGIN`, `TUNNEL_PREFIX`, `TUNNEL_PROTO`.

---

## Features

### Origin Auto-Detection

When `--origin` is not specified, `tunnel-cloud` automatically finds any dev server running in the current directory by matching TCP-listening processes to the project's working directory. This works with any framework or language — Next.js, Vite, Express, Remix, Astro, Python, Go, Ruby, and more.

If multiple projects are running simultaneously, only the server whose working directory matches the current project is selected.

If no server is detected, the CLI exits with an error and asks you to either start your dev server or pass `--origin` explicitly.

### Auto-Restart

By default, `tunnel-cloud start` monitors the tunnel process and automatically restarts it if it dies unexpectedly. The watchdog gives up after 5 consecutive failures within 60 seconds.

Disable with `--no-watch`:

```bash
tunnel-cloud start --domain yourdomain.com --no-watch
```

### Validation

`tunnel-cloud start` performs several checks before connecting:

- **Project directory** — Must contain a `package.json`, or `--name` must be provided.
- **Origin reachable** — Verifies the local dev server is actually running (TCP check).
- **cloudflared installed** — Prompts to auto-install via Homebrew (macOS), apt/yum (Linux), or direct binary download.
- **Cloudflare auth** — Detects missing `cert.pem` and triggers browser login.

### Platform Support

| Platform | Status |
|----------|--------|
| macOS (Intel + Apple Silicon) | Fully supported |
| Linux (x86_64, ARM) | Fully supported |
| Windows (WSL) | Fully supported |

---

## Examples

```bash
# Quick tunnel — random URL, no account needed
npx tunnel-cloud start
# => https://abc123.trycloudflare.com

# Stable subdomain on your own domain
npx tunnel-cloud start --domain numanaral.dev
# => https://tunnel-my-project.numanaral.dev

# Custom name and origin
npx tunnel-cloud start --domain numanaral.dev --name api --origin http://localhost:8080
# => https://tunnel-api.numanaral.dev

# Staging prefix
npx tunnel-cloud start --domain numanaral.dev --prefix staging
# => https://staging-my-project.numanaral.dev

# Stop
npx tunnel-cloud stop

# Full teardown (removes tunnel + DNS record from Cloudflare)
npx tunnel-cloud cleanup
```

---

## Project Integration

Add to your project's `package.json`:

```json
{
  "scripts": {
    "tunnel": "tunnel-cloud start --domain yourdomain.com",
    "tunnel:stop": "tunnel-cloud stop",
    "tunnel:status": "tunnel-cloud status",
    "tunnel:logs": "tunnel-cloud logs",
    "tunnel:cleanup": "tunnel-cloud cleanup"
  }
}
```

Then: `npm run tunnel` / `yarn tunnel`.

---

## How It Works

1. Authenticates with Cloudflare via `cloudflared tunnel login` (one-time, opens browser)
2. Creates a named Cloudflare Tunnel (persists across restarts)
3. Adds a CNAME DNS record `<prefix>-<name>.<domain>` pointing to the tunnel
4. Runs `cloudflared` in the background, proxying traffic to your local server
5. Caches config in `.tunnel/` so subsequent starts only need `tunnel-cloud start`

State files are stored in `.tunnel/` in the project directory. Add it to `.gitignore`.

---

## Roadmap

- **Config file support**: Read from `.tunnelrc` or `tunnel` key in `package.json`.
- **Multiple tunnels**: Support exposing multiple ports/services from one project.
- **`--port` shorthand**: Equivalent to `--origin http://localhost:<port>`.
- **`--no-dns` flag**: Skip DNS route creation (useful if managing DNS manually).
- **Quiet mode**: `--quiet` flag to suppress output (useful in CI).
- **JSON output**: `--json` flag for `status` command (useful for scripting).
- **Test suite**: Unit tests for arg parsing, config resolution, and YAML generation; integration tests for origin auto-detection.

---

## License

[MIT](LICENSE) — Created by <a href="https://numanaral.dev?utm_source=tunnel-cloud-github&utm_medium=readme&utm_campaign=tunnel-cloud">Numan Aral</a>
