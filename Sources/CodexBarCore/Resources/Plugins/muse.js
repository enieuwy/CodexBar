function _nullishCoalesce(lhs, rhsFn) {
  if (lhs != null) {
    return lhs;
  } else {
    return rhsFn();
  }
}
function _optionalChain(ops) {
  let lastAccessLHS = undefined;
  let value = ops[0];
  let i = 1;
  while (i < ops.length) {
    const op = ops[i];
    const fn = ops[i + 1];
    i += 2;
    if ((op === "optionalAccess" || op === "optionalCall") && value == null) {
      return undefined;
    }
    if (op === "access" || op === "optionalAccess") {
      lastAccessLHS = value;
      value = fn(value);
    } else if (op === "call" || op === "optionalCall") {
      value = fn((...args) => value.call(lastAccessLHS, ...args));
      lastAccessLHS = undefined;
    }
  }
  return value;
}
async function _asyncOptionalChain(ops) {
  let lastAccessLHS = undefined;
  let value = ops[0];
  let i = 1;
  while (i < ops.length) {
    const op = ops[i];
    const fn = ops[i + 1];
    i += 2;
    if ((op === "optionalAccess" || op === "optionalCall") && value == null) {
      return undefined;
    }
    if (op === "access" || op === "optionalAccess") {
      lastAccessLHS = value;
      value = await fn(value);
    } else if (op === "call" || op === "optionalCall") {
      value = await fn((...args) => value.call(lastAccessLHS, ...args));
      lastAccessLHS = undefined;
    }
  }
  return value;
}
defineProvider({
  id: "muse",
  name: "Muse Code",
  endpoints: ["https://api.meta.ai", "https://dev.meta.ai"],
  settings: [{ key: "MUSE_DEVICE_TOKEN", title: "Muse login", type: "secure" }],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["dev.meta.ai"],
  async fetchUsage(ctx) {
    const token = ctx.settings.getSecret("MUSE_DEVICE_TOKEN");
    if (!_optionalChain([token, "optionalAccess", (_) => _.startsWith, "call", (_2) => _2("dca:")])) {
      throw ctx.fail.authenticationExpired("Muse Code requires a device-code login. Run `muse login` again.");
    }
    // Keep the device credential off dev.meta.ai requests, which authenticate with the browser session.
    const response = await ctx.http.post("https://api.meta.ai/muse-code/key", {
      body: {},
      headers: { Authorization: `Bearer ${token}`, "x-api-version": "1.0.0", "User-Agent": "CodexBar" },
      timeoutSeconds: 15,
    });
    if (response.status === 401 || response.status === 403) {
      throw ctx.fail.authenticationExpired("Muse Code login was rejected. Run `muse login` again.");
    }
    if (response.status === 429) throw ctx.fail.rateLimited("Muse Code usage requests are rate limited.");
    if (response.status >= 500) throw ctx.fail.providerUnavailable(`Muse Code API returned HTTP ${response.status}.`);
    if (response.status !== 200) throw ctx.fail.apiFailure(`Muse Code API returned HTTP ${response.status}.`);
    const fail = (field) => {
      throw ctx.fail.parseFailure(`Could not parse Muse Code subscription usage: ${field}`);
    };
    const object = (value, field) => {
      if (!value || typeof value !== "object" || Array.isArray(value)) return fail(field);
      return value;
    };
    const number = (value, field) => {
      if (typeof value !== "number" || !Number.isFinite(value)) return fail(field);
      return value;
    };
    const text = (value, field) => {
      if (value === undefined || value === null) return undefined;
      if (typeof value !== "string") return fail(field);
      return value.trim() || undefined;
    };
    const reset = (value) => {
      if (value === undefined || value === null) return undefined;
      const seconds = number(value, "resets_at");
      // Match the native countdown boundary; oversized dates must not discard useful quota data.
      if (seconds <= 0 || seconds > 64092211200) return undefined;
      return ctx.date.unixSeconds(seconds);
    };
    let decoded;
    try {
      decoded = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      return fail("expected JSON");
    }
    const root = object(decoded, "expected a response object");
    for (const key of ["require_payment", "is_subs_active"]) {
      if (root[key] !== undefined && root[key] !== null && typeof root[key] !== "boolean") return fail(key);
    }
    if (root.require_payment === true) {
      throw ctx.fail.permissionDenied("Muse Code requires a payment method. Finish billing at https://dev.meta.ai");
    }
    if (root.is_subs_active !== true) {
      throw ctx.fail.permissionDenied("No Muse Code subscription is active on this login.");
    }
    const plan = text(root.subs_tier_name, "subs_tier_name");
    const rows = [];
    if (plan) rows.push({ label: "Plan", value: plan });
    const snapshot = {
      details: [{ title: "Muse Code subscription", rows }],
      identity: { email: text(root.user_email, "user_email"), loginMethod: _nullishCoalesce(plan, () => "Muse login") },
      dataConfidence: "unknown",
    };
    const percentLabel = (value) => `${ctx.format.number(value, { maximumFractionDigits: 0 })}%`;
    async function webQuota() {
      if (ctx.browser.availability("dev.meta.ai") === "off") return undefined;
      try {
        const headers = { Cookie: await ctx.browser.cookieHeader("dev.meta.ai"), "User-Agent": "CodexBar" };
        const get = async (path) => {
          const response = await ctx.http.get(`https://dev.meta.ai${path}`, { headers, timeoutSeconds: 8 });
          if (response.status === 401 || response.status === 403) {
            ctx.browser.rejectCookie("dev.meta.ai");
            return undefined;
          }
          if (response.status !== 200) return undefined;
          const value = JSON.parse(response.bodyText);
          return value && typeof value === "object" && !Array.isArray(value) ? value : undefined;
        };
        // Only merge quotas when the browser session belongs to the same Meta account as the CLI login.
        const loginEmail = _optionalChain([
          text,
          "call",
          (_3) => _3(root.user_email, "user_email"),
          "optionalAccess",
          (_4) => _4.toLowerCase,
          "call",
          (_5) => _5(),
        ]);
        const me = await get("/api/auth/me");
        const webEmail =
          typeof _optionalChain([me, "optionalAccess", (_6) => _6.email]) === "string"
            ? me.email.trim().toLowerCase()
            : undefined;
        if (!loginEmail || !webEmail || loginEmail !== webEmail) return undefined;
        const teams = await _asyncOptionalChain([
          await get("/api/portal/teams"),
          "optionalAccess",
          async (_7) => _7.teams,
        ]);
        if (!Array.isArray(teams)) return undefined;
        for (const team of teams.slice(0, 2)) {
          const id = _optionalChain([team, "optionalAccess", (_8) => _8.team_id]);
          const teamID = typeof id === "string" ? id : Number.isSafeInteger(id) ? String(id) : "";
          if (!/^[0-9]+$/.test(teamID)) continue;
          const quota = await _asyncOptionalChain([
            await get(`/api/portal/teams/${teamID}/subscription-quota`),
            "optionalAccess",
            async (_9) => _9.subscription_quota,
          ]);
          const parsed = quota && typeof quota === "object" ? parseWebQuota(quota) : null;
          if (parsed) return parsed;
        }
      } catch (error) {
        void error;
      }
      return undefined;
    }
    function parseWebQuota(quota) {
      // Limits and usage are weighted token counts encoded as decimal strings.
      const amount = (value) => {
        const parsed = typeof value === "string" && /^[0-9]+$/.test(value) ? Number(value) : value;
        return typeof parsed === "number" && Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
      };
      const percent = (used, limit) => {
        const u = amount(used);
        const l = amount(limit);
        return u === null || l === null || l <= 0 ? null : Math.min(100, (u / l) * 100);
      };
      const primaryPercent = percent(quota.window_weighted_used, quota.window_weighted_limit);
      const weeklyPercent = percent(quota.weekly_weighted_used, quota.weekly_weighted_limit);
      const seconds = amount(quota.window_duration_secs);
      if (primaryPercent === null || weeklyPercent === null || seconds === null || seconds < 60) return null;
      const resetAt = (value) => {
        const parsed = amount(value);
        return parsed === null || parsed <= 0 || parsed > 64092211200 ? undefined : ctx.date.unixSeconds(parsed);
      };
      return {
        // An idle 5-hour window has no reset time until the next request starts it.
        primary: {
          usedPercent: primaryPercent,
          windowMinutes: Math.round(seconds / 60),
          resetsAt: resetAt(quota.window_resets_at),
        },
        secondary: { usedPercent: weeklyPercent, windowMinutes: 10080, resetsAt: resetAt(quota.weekly_resets_at) },
      };
    }
    if (root.subs_usage === undefined || root.subs_usage === null) {
      // The login response omits quotas while the 5-hour window is idle, even when the weekly limit has usage.
      // The dev.meta.ai usage page reads the same subscription quota with the browser session.
      const web = await webQuota();
      if (!web) {
        rows.push({ label: "Quota", value: "Not included in this login response" });
        return snapshot;
      }
      rows.push({ label: "5 hours", value: percentLabel(web.primary.usedPercent) });
      rows.push({ label: "Weekly", value: percentLabel(web.secondary.usedPercent) });
      return { usage: { ...snapshot, ...web, dataConfidence: "exact" }, sourceLabel: "oauth+web" };
    }
    const usage = object(root.subs_usage, "subs_usage");
    const window = object(usage.window, "missing subscription window");
    const weekly = object(usage.weekly, "missing weekly window");
    const minutes = Math.round(number(window.window_duration_mins, "window_duration_mins"));
    if (!Number.isSafeInteger(minutes) || minutes <= 0) return fail("window_duration_mins");
    const primaryPercent = Math.min(100, Math.max(0, number(window.used_percent, "window.used_percent")));
    const weeklyPercent = Math.min(100, Math.max(0, number(weekly.used_percent, "weekly.used_percent")));
    rows.push({ label: "5 hours", value: percentLabel(primaryPercent) });
    rows.push({ label: "Weekly", value: percentLabel(weeklyPercent) });
    return {
      ...snapshot,
      primary: { usedPercent: primaryPercent, windowMinutes: minutes, resetsAt: reset(window.resets_at) },
      secondary: { usedPercent: weeklyPercent, windowMinutes: 10080, resetsAt: reset(weekly.resets_at) },
      dataConfidence: "exact",
    };
  },
});
