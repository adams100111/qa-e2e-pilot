# Applying a row's variant (ship profile)

Under the ship profile (ADR-0030) a UX row can carry a `variant` object
(`references/checklist-json-schema.md` in generating-qa-checklist, D1):

```json
{"variant": {"viewport": "mobile", "locale": "ar", "colorScheme": "dark"}}
```

Every key is optional. An absent key means the run's primary value: the first
`responsiveMatrix` entry, the first entry of `locales`, and `light`. The
values come from the run's `effective-config.json` (written by
`scripts/profile.sh resolve` at phase 0), never from raw `.qa/config.json`.

## Order

Apply the variant before Step 1, in this order, then re-snapshot and wait for
the page to settle:

1. **Viewport.** Resolve `variant.viewport` against `responsiveMatrix` by `id`
   (or a literal `WxH`) and call `browser_resize` with that width and height.
2. **Color scheme.** Call the emulate-media capability
   (`browser_emulate_media` on Playwright) with `colorScheme` set to the
   variant's value. It changes `prefers-color-scheme` for the page, so an app
   that themes from the media query switches at once. An app with its own
   theme toggle that ignores the media query is a finding for the report
   (dark mode does not follow the system setting), not something to work
   around by clicking the toggle on a read-only revisit.
3. **Locale.** Switch through the app's own locale control (language menu,
   profile setting, or a locale route segment the app itself links to). A
   locale switch is a navigation, so follow it with `browser_network_requests`
   like any other. An RTL locale (`ar`, `he`, `fa`, `ur`) turns on the RTL and
   i18n detector families (script mismatch, raw key, untranslated fallback).

## Rules

- Record the applied variant on every finding and on the screenshot path
  (`evidence/<criterion-id>/screenshot-after.png` is per row, and a ux-revisit
  row's id already carries `@<viewport>-<locale>-<scheme>`).
- Reset to the primary variant (desktop, first locale, light) before the next
  row that has no `variant`, so a later functional criterion never runs at a
  leftover mobile size or in dark mode.
- A driver without the emulate-media capability cannot verify a dark row:
  record it `blocked` with the reason "driver `<id>` lacks emulate-media";
  never take a light screenshot and call it dark.
- An app with no locale control for the variant's locale: record the row
  `blocked` with the reason, and list it in the report.
- Variants never multiply functional criteria. Only ux-revisit `load-clean`
  rows and the one P1 journey that `journeys.sh expand-variant` copies run at
  a non-primary variant.
