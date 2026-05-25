# Installing qa-e2e-pilot

Three install methods. All three make the **agent** (`qa-e2e-pilot`), the **`/qa-run`** command, and the nine **skills** discoverable by Claude Code. After any of them, restart Claude Code or run `/agents` to load them.

---

## Method A — Plugin marketplace (recommended)

```
/plugin marketplace add adams100111/qa-e2e-pilot
/plugin install qa-e2e-pilot
```

`marketplace add` also accepts a local path, which is handy for development:

```
/plugin marketplace add /home/dev/repos/qa-e2e-pilot
/plugin install qa-e2e-pilot
```

Verify: the agent appears in `/agents`, `/qa-run` appears in the command list, and the skills load on demand.

---

## Method B — npx skills installer

```
npx skills@latest add adams100111/qa-e2e-pilot
```

This reads [`scripts/skills.json`](./scripts/skills.json) and installs the agent, command, and skills. Re-run to update.

---

## Method C — Manual symlink (fallback)

Clone the repo and run the installer; it symlinks the agent, command, and each skill into `~/.claude` (override with `CLAUDE_CONFIG_DIR`):

```
git clone -b main https://github.com/adams100111/qa-e2e-pilot
bash qa-e2e-pilot/scripts/install.sh
```

Options:

- `bash scripts/install.sh --copy` — copy instead of symlink (for filesystems without symlink support).
- `bash scripts/install.sh --uninstall` — remove what the installer created.

---

## Per-project configuration

`qa-e2e-pilot` is configured **per project under test** (so one machine can QA several apps). In the project you want to QA:

```
mkdir -p .qa
cp <path-to-plugin>/.qa/config.json.example .qa/config.json
```

Edit `.qa/config.json`:

| Field | Meaning |
|---|---|
| `baseUrl` | where the app is served, e.g. `http://localhost:3000` |
| `apiOrigin` | optional — set only if the backend API is a different origin than `baseUrl` (enables cross-origin probing); leave `""` for same-origin |
| `auth.storageState` | path to a Playwright `storageState` JSON so auth survives between sessions |
| `drivers[]` | the browser pool; each entry has a platform `preset` (below) |
| `maxParallel` | cap on the narrow parallel path (most runs are sequential) |
| `repos[]` | `{ "role": "frontend"\|"backend"\|"reference", "path": "..." }` — all optional |
| `allowApiWrites` | default `false`; must be `true` **and** `seedableEnvMarker` present to allow any API write/seed |
| `seedableEnvMarker` | name of an env var that marks a disposable/seedable environment |

`.qa/config.json`, `.qa/runs/`, and `.qa/auth/` are git-ignored by default — only `config.json.example` is tracked.

### Driver platform presets

The default driver needs no setup:

```json
{ "id": "managed", "server": "playwright", "preset": "managed" }
```

To **attend your own logged-in Chrome** (opt-in), add a CDP driver with the preset for your platform. The preset resolves the CDP endpoint; `cdpEndpoint` overrides it.

| Preset | Resolves to | Use when |
|---|---|---|
| `managed` | the built-in Playwright browser | default, any OS, zero-config |
| `windows+wsl` | the Windows host (`/etc/resolv.conf` nameserver) `:9222` | Claude Code in WSL, Chrome on Windows |
| `windows` | `http://localhost:9222` | native Windows |
| `wsl` | `http://localhost:9222` | a CDP server running inside WSL itself |
| `linux` / `mac` | `http://localhost:9222` | native Linux/macOS |

For `windows+wsl` on **mirrored** WSL2 networking (where `localhost` already bridges to Windows), set `cdpEndpoint` to `http://localhost:9222` — an explicit `cdpEndpoint` always overrides the preset.

Start Chrome with remote debugging first, e.g.:

```
# Windows (PowerShell)
& "C:\Program Files\Google\Chrome\Application\chrome.exe" --remote-debugging-port=9222

# Linux / macOS
google-chrome --remote-debugging-port=9222
```

Pre-flight (`preflight.sh`) enumerates and pings each configured driver and tells you which are reachable before a run starts.

---

## Verifying the install

1. `/agents` lists **qa-e2e-pilot**.
2. The command list includes **/qa-run**.
3. From a configured project: `/qa-run <a feature> .qa/checklist.md` runs the pipeline and writes `.qa/runs/<run-id>/report.html`.

If pre-flight aborts, read its message — it checks app liveness, the `storageState` file, driver reachability, and build-id freshness, and tells you exactly what's missing.
