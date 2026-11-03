// Content shared by both reports: the audit baseline, the rules every
// client inherits, and the contract appendix builder.

export function baselineSection(r, s, { audience }) {
  r.h2('Audit baseline');
  r.p(`This document was generated on ${r.info.date} directly from the repository's local migrations. Every function signature, EXECUTE grant, enum value, status set and cron job quoted in the appendices is parsed from \`supabase/migrations\` at build time, so the document and the schema cannot drift apart silently: re-running the generator re-reads them.`);
  r.kv([
    ['Migrations read', `${s.files.length} files, ${s.files[0].slice(0, 14)} → ${s.latest.slice(0, 14)}`],
    ['Latest migration', s.latest],
    ['Public SQL functions', `${s.functions.size} (latest definitions), of which ${[...s.functions.keys()].filter((n) => s.grants.get(n)?.has('authenticated')).length} are executable by \`authenticated\``],
    ['pgTAP coverage', `${s.tests.assertions.toLocaleString('en-US')} assertions in ${s.tests.files} files`],
    ['Edge Functions', `${s.edgeFunctions.length} gateways in supabase/functions`],
    ['Scheduled jobs (pg_cron)', `${s.cron.size} active jobs`],
    ['Governing documents', 'Spec A (2026-10-05) and addenda A1–A6, including A6 §19.4 and §20 (2026-11-02)'],
    ['Deployment state', 'The remote project holds the 29 migrations to 20261015130200 (A1, A2). Everything after, including all of Monvelo, is built and tested locally and is not pushed.'],
    ['Audience', audience],
  ]);
}

export function rulesSection(r) {
  r.h2('Rules every client inherits (Spec A §9)');
  r.p('These rules are enforced in the database and the gateways. A client cannot weaken them; it can only fail to respect them and receive an error. Each one shapes a front-end decision.');
  r.table(['Rule', 'What the client must do'], [
    ['**No direct client writes.** `authenticated` has SELECT only; every mutation is a SECURITY DEFINER RPC.', 'Never call `.insert()`, `.update()` or `.delete()` through supabase-js. Every write is `rpc()` or a gateway POST.'],
    ['**The tenant comes from the JWT,** re-verified live against `tenant_users`.', 'Never send a `tenant_id` parameter. Switching tenant calls `set_active_tenant` and then refreshes the session so the access-token hook re-issues claims.'],
    ['**Gateways forward the caller\'s JWT,** never the service-role key, for user work.', 'Send `Authorization: Bearer <user JWT>` to every `/functions/v1/<name>` call. No service key ever ships in an app or a browser bundle.'],
    ['**Every mutation takes `p_idempotency_key uuid` first,** generated at enqueue time.', 'Generate the UUID when the user acts, store it with the queued mutation, and resend the same key on every retry.'],
    ['**Contact privacy:** buyer contacts live only in `order_contacts`; `bvn_nin_hash` only in `user_secure_profiles`.', 'Never cache another person\'s phone or identity number on the device. Screens show what the RPC returns and nothing more.'],
    ['**Workflow statuses are `text` + CHECK;** stable sets are enums.', 'Treat status strings as an open set in the UI: render unknown values with a neutral badge instead of crashing.'],
    ['**Money is NUMERIC(15,2), quantities NUMERIC(14,3), timestamps timestamptz.**', 'Parse money as strings into a decimal type; never float arithmetic. Render times in Africa/Lagos from server timestamps.'],
  ], { widths: [0.45, 0.55], caption: 'Database rules and their front-end consequences.' });
}

export function errorSection(r) {
  r.h2('Error contract');
  r.p('RPC errors carry a SQLSTATE; gateways map them to HTTP. The client maps both to one of three behaviours: show and stop, retry, or re-authenticate.');
  r.table(['SQLSTATE / HTTP', 'Meaning', 'Client behaviour'], [
    ['42501 / 403', 'Not allowed: wrong role, out of scope, not a member, the request\'s raiser deciding its own hold.', 'Show a neutral "not available to you" message. Do not retry. Refresh the role cache.'],
    ['P0001 / 422', 'A business rule refused the action (the message is written for people, e.g. the exposure-cap sentence).', 'Show the server message verbatim. Move a queued entry to "Needs attention".'],
    ['22023 (PostgREST 400)', 'Invalid parameter on a direct RPC (a reason under 10 characters, p_weeks outside 1–52, p_allow null). Not in the gateway contract.', 'Validate on the client first so this is rare; show the message beside the field.'],
    ['23505 / 409', 'Conflict (e.g. a duplicate the database refuses).', 'Show and stop; refresh the affected list.'],
    ['TF001 / 409', 'Insufficient stock; details carry {sku_code, available, requested}.', 'Offer to reduce the quantity to `available`.'],
    ['TF002 / 409', 'Idempotency key reused with a different payload.', 'Terminal. Never generate a new key silently for the same user action.'],
    ['40001, 55P03 / 503; network failure', 'Transient (serialisation, lock timeout, no signal).', 'Retry with exponential backoff, 2 s to 5 min, same idempotency key.'],
    ['PGRST301 / 401', 'Session expired between the gateway check and the RPC.', 'Refresh the session once; on failure, return to sign-in and keep the queue.'],
  ], { widths: [0.2, 0.42, 0.38], caption: 'Error mapping (Spec A §3.5, §7.3; supabase/functions/_shared/core/errors.ts).' });
}

export function contractAppendix(r, s, title, groups) {
  r.h1(title);
  r.p('Signatures are the latest `create or replace function` in migration order. "Callers" are the roles holding EXECUTE after every grant and revoke. `service_role` means only a gateway can reach the function; `authenticated` means the app calls it with the user\'s JWT, and the function itself checks the role and scope live.');
  for (const [heading, names] of groups) {
    r.h2(heading);
    r.table(['Function', 'Callers', 'Returns'], names.map((n) => {
      const f = s.fn(n);
      const ret = f ? (f.returns.startsWith('table') ? 'table (see below)' : f.returns) : '—';
      return [s.sig(n), s.callers(n), ret];
    }), { widths: [0.62, 0.19, 0.19], mono: [0], size: 8.2 });
    for (const n of names) {
      const cols = s.returnCols(n);
      if (cols.length) {
        r.h3(`${n} → result columns`);
        r.table(['Column', 'Type'], cols, { widths: [0.4, 0.6], mono: [0, 1], size: 8.2 });
      }
    }
  }
}

export function enumAppendix(r, s, enumNames, checkKeys) {
  r.h2('Enumerations and status sets');
  r.table(['Name', 'Values (in definition order)'], [
    ...enumNames.map((n) => [n, s.enumValues(n).join(', ') || '—']),
    ...checkKeys.map((k) => [`${k} (CHECK)`, s.checkValues(k).join(', ') || '—']),
  ], { widths: [0.34, 0.66], mono: [0], size: 8.4 });
}
