# Census stack adapters

A census adapter reads what an app's own code declares — routes, front-end pages, scheduled jobs,
mail and notification classes, locales — and prints it as one JSON object. `scripts/census.sh build
--adapter <file>` merges that with the per-role crawl into `.qa/census.json` and computes the diffs
(unreachable, overreach, crawl-only). Stack specifics live only here; nothing else in the engine
knows about Laravel, Next.js or any other framework.

## Invocation

```
adapters/census/<stack>.sh --repo <path> [--exec-prefix "<prefix>"]
```

- `--repo` is the app root. Every command the adapter runs is run from this directory.
- `--exec-prefix` is the project's config `exec.prefix` (string, default `""`). It is word-split and
  prepended to every command the adapter runs (whitespace split only: shell quotes, escapes and
  operators are not interpreted, each word is one argv element), so `"ddev exec"` turns `php artisan route:list --json`
  into `ddev exec php artisan route:list --json`. Other examples: `"devenv shell --"`,
  `"docker compose exec -T app"`. File scans read `--repo` directly and never use the prefix.
- Adapters are read-only. They never write to the repo, the database or the network.

## Output (stdout)

Success, exit 0:

```json
{"adapter":"<stack>","ok":true,
 "surfaces":[{"surfaceId":"GET /admin/hackathons/{hackathon}","kind":"endpoint",
              "pattern":"/admin/hackathons/{hackathon}","method":"GET",
              "permissionHints":["can:hackathons.view"],"source":"adapter"},
             {"surfaceId":"page:Admin/Hackathons/Show","kind":"page","pattern":"Admin/Hackathons/Show",
              "method":null,"permissionHints":[],"source":"adapter"}],
 "jobs":[{"id":"hackathons:close-registration","schedule":"0 0 * * *"}],
 "mails":[{"id":"App\\Mail\\TeamInvite"}],
 "notifications":[{"id":"App\\Notifications\\JudgeAssigned"}],
 "locales":["ar","en"],
 "warnings":["skipped vendor route: horizon"]}
```

Failure, exit 3:

```json
{"adapter":"<stack>","ok":false,"error":"<message>"}
```

Exit 1 is a usage error (bad or missing flags); it prints to stderr only.

### Field rules

| Field | Rule |
|---|---|
| `surfaceId` | `<METHOD> <pattern>` for endpoints (`GET /h/{slug}`), `page:<component>` for front-end pages. `census.sh` parses these two prefixes, so they are exact. |
| `kind` | `endpoint` or `page`. |
| `pattern` | Endpoints: the path with a leading `/`, params as `{name}`, an optional trailing param as `{name?}`. Pages: the component name. |
| `method` | One HTTP method per surface, upper case. A route serving several methods yields one surface each; `HEAD` is dropped when `GET` is present. `null` for pages. |
| `permissionHints` | Sorted, unique strings taken from the stack's own access declarations (Laravel: route middleware). Empty when none. Hints are leads for the access matrix, not verdicts. |
| `source` | Always `"adapter"`. |
| `jobs` | `{id, schedule}`; `schedule` is the cron expression the stack reports. |
| `mails`, `notifications` | `{id}`, the class name the code declares. |
| `locales` | Sorted locale codes. |
| `warnings` | Anything skipped or missing (vendor routes, absent page dirs). Never used to hide a failure. |

Output is compact JSON with sorted keys and raw UTF-8 (Arabic paths are not `\u`-escaped). Adapters
that build JSON are dual-engine (`jq` or `python3`, `QA_ENGINE=jq|python3` forces one) and the two
engines produce byte-identical output.

### Failure is never an empty success

If the stack's tool is missing, a command exits non-zero, or its output cannot be parsed, the adapter
prints `ok:false` with the reason and exits 3. It never prints `ok:true` with empty surfaces to cover
a failure. `census.sh` then builds the census from the crawl alone and records
`adapter-failed: <stack>: <error>` in its warnings.

## Laravel (`laravel.sh`)

Commands, run from `--repo` with the prefix:

- `php artisan route:list --json` — an array of `{domain, method, uri, name, action, middleware}`.
  `method` is pipe-joined (`GET|HEAD`), `uri` has no leading slash, `middleware` is an array (or a
  newline-joined string on older versions).
- `php artisan schedule:list` — text; each task line gives the cron expression and the command
  (`php artisan <name>` is reported as `<name>`).

Scans:

- Pages: `resources/js/pages`, `resources/js/Pages` → `page:<Path/Name>`;
  `Modules/<M>/resources/js/pages` → `page:<M>::<Path/Name>` (the `Module::Page` name an Inertia
  module resolver renders). Files `*.tsx`, `*.jsx`, `*.vue`, `*.svelte`; test, spec and story files
  and anything under `components`, `partials`, `hooks`, `lib`, `utils`, `types`, `__tests__` are not
  pages.
- Mail and notification classes: `app/Mail`, `app/Notifications`, `Modules/*/app/Mail`,
  `Modules/*/app/Notifications` (recursive). The id is the file's declared namespace plus the class
  file name, or a namespace derived from the path when the file declares none.
- Locales: `lang/` and `resources/lang/` (`*.json` names and subdirectories, `vendor` excluded).

Permission hints are the middleware entries matching `can:*`, `permission:*`, `role:*` and
`license.feature:*`; a resolved `Illuminate\Auth\Middleware\Authorize:<ability>` is reported as
`can:<ability>`. Routes under `_ignition`, `telescope`, `horizon` and `sanctum/csrf-cookie` are
skipped and each prefix is named once in `warnings`.

## Next.js (`nextjs.sh`), Express (`express.sh`)

Static scanners (no runtime tool, `--exec-prefix` accepted and unused). Every surface carries
`"confidence":"static"` and dynamic segments are `{name}`.

- Next.js: `app/**/page.{tsx,jsx,ts,js}` and `pages/**/*.{tsx,jsx}` (also under `src/`; `_app`,
  `_document` and `api/` excluded) become `GET <route>` endpoints, because file routing names URLs, not
  components. `app/api/**/route.*` yields one surface per exported `GET|POST|PUT|PATCH|DELETE`
  handler. Route groups `(g)` and slots `@s` vanish; `[id]` is `{id}`, `[...x]` is `{x}`,
  `[[...x]]` is `{x?}`.
- Express: single-line `app.<method>('/path'` and `<name>Router|router.<method>('/path'` calls
  (string-literal paths). `app.use('/prefix', router)` mounts are not applied; a warning says so.

## Rails (`rails.sh`)

Runs `<prefix> bin/rails routes` from `--repo` and parses the table. `(.:format)` is dropped,
`(/:x)` becomes `/{x?}`, `:id` and `*rest` become `{id}` and `{rest}`. Rows without a verb
(mounted engines) are skipped; `/rails/*` and `/cable` are skipped and named in `warnings`. A
missing or failing `bin/rails` is `ok:false`.

## Django (`django.sh`)

Runs `<prefix> python manage.py show_urls` (django-extensions); every route is `GET` because that
command reports no methods. When the command is unavailable or fails, the adapter scans `urls.py`
files for `path(`, `re_path(` and `url(` entries (following `include('pkg.urls')` when it resolves
inside the repo), marks surfaces `"confidence":"static"`, and names the fallback and any
unresolved include in `warnings`. No `manage.py` and no `urls.py` is `ok:false`.

## Generic (`generic.sh`)

No stack knowledge: prints `{"adapter":"generic","ok":true,"surfaces":[],"warnings":["crawl-only
census"]}`, so the census is the crawl alone.

## Adding an adapter

1. Create `adapters/census/<stack>.sh` with the invocation and output above (the non-Laravel adapters
   share `adapters/census/_lib.sh`: argument parsing, prefix handling, `ok:false` and the dual-engine emitter).
2. Static scanners (no runtime tool) mark each surface `"confidence":"static"` and normalise dynamic
   segments to `{param}`.
3. Add a fixture repo under `tests/census-adapters/fixtures/<stack>/` and cases to
   `tests/census-adapters/run.sh`, including a run through `scripts/census.sh build` to prove the
   output is accepted.
