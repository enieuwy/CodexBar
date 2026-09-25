---
summary: "Muse Code authentication, subscription windows, and local token history."
read_when:
  - Configuring Muse Code in CodexBar
  - Debugging Muse Code login or subscription usage errors
---

# Muse Code

CodexBar shows Muse Code subscription usage and local token history. Subscription quota comes from the bundled JavaScript provider; token history comes from the Muse CLI's session logs. Dollar costs remain unavailable because those logs do not provide billing amounts.

## Authentication

Sign in with the Muse CLI:

```bash
muse login
```

CodexBar reads the same Keychain item the CLI stores (`ai.meta.dev.credentials` / `meta`) and sends only the device-code `dca:` access token to `POST https://api.meta.ai/muse-code/key`. Meta dashboard `LLM_` keys and Muse-minted `LLM|` inference keys cannot read this quota (they 401 on that mint endpoint).

Credential precedence: when `providers.meta.access_token` is present inline in the CLI metadata file `~/.config/muse/auth.json`, that token selects the account queried and takes precedence over Keychain. Otherwise CodexBar reads the device-code token from the CLI's Keychain item. An `auth.json` with `"mechanism": "oauth"` but no inline token still counts as a login; the token then comes from Keychain. Override the file path with `MUSE_AUTH_PATH` if needed.

The Keychain item belongs to the Muse CLI, so its access list may not include CodexBar. CodexBar checks that access list without requesting the token. If access would require a prompt or the check cannot complete, refreshes fail promptly without reading the token. This applies to background refreshes, manual app refreshes, and the `codexbar` CLI: CodexBar never prompts Keychain for Muse. Detecting whether a Muse login exists never requests its secret. A Keychain-only item detected as requiring interaction keeps the access diagnostic even when the CLI metadata file is absent.

When a Keychain-only login cannot be read because Keychain access is disabled, the diagnostic names **Disable Keychain access** in **Settings → Advanced**. Inline CLI tokens still work with Keychain access disabled.

## Data shown

The bundled `muse.ts` plugin owns the JSON request and subscription parsing on macOS and Linux. Native code only
reads the CLI-owned credential and registers the provider. The returned inference key and payment metadata are
discarded; CodexBar never writes them to the CLI's credential store.

- Plan name from `subs_tier_name` (for example Muse Code Power Usage).
- 5-hour window percent, duration, and `resets_at`.
- Weekly window percent and `resets_at`.

Reset timestamps outside the supported date range are omitted without discarding the window's usage percentage.

Pay-as-you-go accounts without `is_subs_active` are reported as having no subscription rather than a fake 0% bar. Accounts that still need a payment method are reported as billing-incomplete.

An active subscription whose mint response omits `subs_usage` or returns it as `null` keeps its plan and identity. Meta omits `subs_usage` while the 5-hour window is idle, even when the weekly limit has usage.

## Web quota fallback

When `subs_usage` is missing, CodexBar reads the same subscription quota that the `dev.meta.ai/usage` page shows, using your browser session for `dev.meta.ai` (the `llama_dev_sess` cookie):

1. `GET https://dev.meta.ai/api/auth/me`. The session email must match the CLI login email, or CodexBar ignores the web quota.
2. `GET https://dev.meta.ai/api/portal/teams`
3. `GET https://dev.meta.ai/api/portal/teams/{team_id}/subscription-quota` for up to two teams, using the first team that returns a quota.

Usage is `used / limit` for the 5-hour and weekly weighted limits. An idle 5-hour window shows 0% with no reset time, because the window starts with the next request. The source label becomes `oauth+web`. The device-code token is sent only to `api.meta.ai`; `dev.meta.ai` requests carry only the browser cookie.

**Settings → Providers → Muse Code → Cookie source** controls the fallback. It is **Off** by default, so CodexBar reads no browser data until you choose a source. **Automatic** imports the cookie from Chrome or Firefox, **Manual** uses a pasted Cookie header or cURL capture from `dev.meta.ai`. If the fallback is off, has no session, belongs to another account, is rejected, times out, or returns an unexpected shape, the card keeps **Quota: Not included in this login response** and no quota bars. Malformed mint quota objects still fail parsing; missing windows never become invented 0% usage.

## Local token history

Enable local usage tracking to show today's tokens, recent daily history, and token comparisons below the subscription windows. The command `codexbar cost --provider muse` also reports tokens; its JSON keeps unavailable monetary fields absent. Local history requires no provider request, credential access, or pricing download.

The reader uses `$MUSE_SESSIONS_DIR`, or `$XDG_DATA_HOME/muse/sessions` (default `~/.local/share/muse/sessions`). It reads `YYYY/MM/DD/session/session.jsonl` files and buckets turns by their recorded timestamp in the local calendar, including turns written after a session's directory date. This is machine-local history across the selected session tree, not an account billing statement or a quota estimate.

Only `model_completed` and `automated_review_completed` inference records count. Tokens total input plus output; cached and reasoning counters are subsets, so they are not added again. CPU telemetry, child rollups, and goal attribution do not duplicate usage. Unknown models keep their recorded token totals and remain unpriced.

Scans are bounded to 30 seconds and 2 GiB of newly read data per refresh, with per-file and per-line bounds. Newly parsed events within the requested dates have a separate 16 MiB conservative size budget, and caches have a 64 MiB limit checked before JSON encoding. Completed files are cached by file identity and precise timestamps; subsequent refreshes can reach additional files without rereading unchanged logs. Interrupted files restart on the next refresh. Changed roots, requested date ranges, calendars, and timezones invalidate cached bucketing. Corrupt records, unsupported usage shapes, unreadable files, and exhausted budgets produce explicitly partial or unavailable history, preserving valid recorded subtotals. An unavailable day is never presented as a measured zero.

## Privacy

The mint response can include a card brand/last-four `payment_method` field. CodexBar does not display it. Email and plan stay on the Muse identity card.
