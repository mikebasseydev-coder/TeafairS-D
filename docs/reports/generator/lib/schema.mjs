// Reads supabase/migrations in filename order and extracts the data
// contracts the reports cite: the latest definition of each function
// (arguments and return shape), EXECUTE grants, enums with their added and
// renamed values, CHECK status sets, table columns, and pg_cron jobs.
// Nothing is hand-copied: if a migration changes, the appendices follow.
import fs from 'node:fs';
import path from 'node:path';

function balanced(src, openIdx) {
  // src[openIdx] === '('; returns the index of the matching ')'
  let depth = 0;
  for (let i = openIdx; i < src.length; i++) {
    const c = src[i];
    if (c === '(') depth++;
    else if (c === ')') { depth--; if (depth === 0) return i; }
  }
  return -1;
}

const squash = (s) => s.replace(/--[^\n]*/g, '').replace(/\s+/g, ' ').trim();

export function loadSchema(root) {
  const migDir = path.join(root, 'supabase', 'migrations');
  const files = fs.readdirSync(migDir).filter((f) => f.endsWith('.sql')).sort();
  const functions = new Map();   // name -> { args, returns, file }
  const grants = new Map();      // name -> Set(roles)
  const enums = new Map();       // name -> [values]
  const tables = new Map();      // name -> { columns: [[name, type]], file }
  const checks = new Map();      // constraint name -> [values]
  const cron = new Map();        // job -> { schedule, file }

  for (const f of files) {
    const src = fs.readFileSync(path.join(migDir, f), 'utf8');

    // functions
    const fnRe = /create\s+or\s+replace\s+function\s+public\.([a-z0-9_]+)\s*\(/gi;
    let m;
    while ((m = fnRe.exec(src))) {
      const open = m.index + m[0].length - 1;
      const close = balanced(src, open);
      if (close < 0) continue;
      const args = squash(src.slice(open + 1, close));
      const after = src.slice(close + 1, close + 1600);
      const r = /^\s*returns\s+([\s\S]*?)\s*(?:\n\s*)?(?:language|as\s+\$|stable|immutable|volatile|security|set\s+search_path)/i.exec(after);
      let returns = r ? squash(r[1]) : '';
      if (/^table\s*\(/i.test(returns)) {
        const ti = after.toLowerCase().indexOf('table');
        const to = after.indexOf('(', ti);
        const tc = balanced(after, to);
        returns = 'table (' + squash(after.slice(to + 1, tc)) + ')';
      }
      // a constant function (`as $$ select 100000.00::numeric(15,2); $$`) keeps its value
      const k = /^[\s\S]*?as\s+\$\$\s*select\s+(-?[0-9.]+)\s*(?:::[a-z0-9_(), ]+)?\s*;?\s*\$\$/i.exec(after);
      functions.set(m[1].toLowerCase(), { args, returns, file: f, constant: k ? Number(k[1]) : null });
    }

    // dropped functions leave the contract (a later create brings them back)
    const dRe = /drop\s+function\s+(?:if\s+exists\s+)?public\.([a-z0-9_]+)\s*\(/gi;
    const created = [...src.matchAll(/create\s+or\s+replace\s+function\s+public\.([a-z0-9_]+)\s*\(/gi)];
    while ((m = dRe.exec(src))) {
      const name = m[1].toLowerCase();
      const recreatedLater = created.some((c) => c[1].toLowerCase() === name && c.index > m.index);
      grants.delete(name); // Postgres drops the grants with the function
      if (!recreatedLater) functions.delete(name);
    }

    // EXECUTE grants (latest statement wins per role)
    const gRe = /(grant|revoke)\s+execute\s+on\s+function\s+([^;]*?)\s+(to|from)\s+([a-z_,\s]+);/gi;
    while ((m = gRe.exec(src))) {
      const roles = m[4].split(',').map((x) => x.trim().toLowerCase()).filter(Boolean);
      for (const fm of m[2].matchAll(/public\.([a-z0-9_]+)\s*\(/gi)) {
        const name = fm[1].toLowerCase();
        const set = grants.get(name) ?? new Set();
        for (const role of roles) {
          if (m[1].toLowerCase() === 'grant') set.add(role); else set.delete(role);
        }
        grants.set(name, set);
      }
    }

    // enums
    const eRe = /create\s+type\s+public\.([a-z0-9_]+)\s+as\s+enum\s*\(([^)]*)\)/gi;
    while ((m = eRe.exec(src))) enums.set(m[1], [...m[2].matchAll(/'([^']+)'/g)].map((x) => x[1]));
    const aRe = /alter\s+type\s+public\.([a-z0-9_]+)\s+add\s+value\s+(?:if\s+not\s+exists\s+)?'([^']+)'/gi;
    while ((m = aRe.exec(src))) { const v = enums.get(m[1]) ?? []; if (!v.includes(m[2])) v.push(m[2]); enums.set(m[1], v); }
    const rRe = /alter\s+type\s+public\.([a-z0-9_]+)\s+rename\s+value\s+'([^']+)'\s+to\s+'([^']+)'/gi;
    while ((m = rRe.exec(src))) { const v = enums.get(m[1]) ?? []; enums.set(m[1], v.map((x) => (x === m[2] ? m[3] : x))); }

    // tables
    const tRe = /create\s+table\s+(?:if\s+not\s+exists\s+)?public\.([a-z0-9_]+)\s*\(/gi;
    while ((m = tRe.exec(src))) {
      const open = m.index + m[0].length - 1;
      const close = balanced(src, open);
      const body = src.slice(open + 1, close);
      // split on top-level commas
      const parts = []; let depth = 0, cur = '';
      for (const c of body) {
        if (c === '(') depth++; if (c === ')') depth--;
        if (c === ',' && depth === 0) { parts.push(cur); cur = ''; } else cur += c;
      }
      parts.push(cur);
      const columns = parts.map(squash).filter(Boolean)
        .filter((p) => !/^(constraint|primary\s+key|unique|check|foreign\s+key|exclude)\b/i.test(p))
        .map((p) => { const [name, ...rest] = p.split(' '); return [name, rest.join(' ')]; });
      tables.set(m[1], { columns, file: f });
      // inline status checks
      for (const [col, def] of columns) {
        const c = /check\s*\(\s*[a-z_]+\s+in\s*\(([^)]*)\)/i.exec(def);
        if (c) checks.set(`${m[1]}.${col}`, [...c[1].matchAll(/'([^']+)'/g)].map((x) => x[1]));
      }
    }
    const acRe = /alter\s+table\s+(?:only\s+)?public\.([a-z0-9_]+)\s+add\s+constraint\s+([a-z0-9_]+)\s+check\s*\(\s*([a-z_]+)\s+in\s*\(([^)]*)\)/gi;
    while ((m = acRe.exec(src))) checks.set(`${m[1]}.${m[3]}`, [...m[4].matchAll(/'([^']+)'/g)].map((x) => x[1]));
    const acolRe = /alter\s+table\s+(?:only\s+)?public\.([a-z0-9_]+)\s+add\s+column\s+(?:if\s+not\s+exists\s+)?([a-z0-9_]+)\s+([^,;]+)/gi;
    while ((m = acolRe.exec(src))) {
      const t = tables.get(m[1]);
      if (t && !t.columns.some(([n]) => n === m[2])) t.columns.push([m[2], squash(m[3])]);
    }

    // cron
    const cRe = /cron\.schedule\(\s*'([^']+)'\s*,\s*'([^']+)'/gi;
    while ((m = cRe.exec(src))) cron.set(m[1], { schedule: m[2], file: f });
    const uRe = /cron\.unschedule\(\s*'([^']+)'/gi;
    while ((m = uRe.exec(src))) cron.delete(m[1]);
  }

  // pgTAP
  const testDir = path.join(root, 'supabase', 'tests', 'database');
  let testFiles = [], assertions = 0;
  if (fs.existsSync(testDir)) {
    testFiles = fs.readdirSync(testDir).filter((f) => f.endsWith('.sql'));
    for (const f of testFiles) {
      const t = fs.readFileSync(path.join(testDir, f), 'utf8');
      const p = /select\s+plan\s*\(\s*(\d+)\s*\)/i.exec(t);
      if (p) assertions += Number(p[1]);
    }
  }
  const fnDir = path.join(root, 'supabase', 'functions');
  const edgeFunctions = fs.existsSync(fnDir)
    ? fs.readdirSync(fnDir, { withFileTypes: true }).filter((e) => e.isDirectory() && !e.name.startsWith('_')).map((e) => e.name)
    : [];

  return {
    files, functions, grants, enums, tables, checks, cron, edgeFunctions,
    tests: { files: testFiles.length, assertions },
    latest: files[files.length - 1],

    fn(name) { return functions.get(name) ?? null; },
    // the value of a constant SQL function, as the latest migration defines it
    constant(name) {
      const v = functions.get(name)?.constant;
      if (v == null) throw new Error(`${name}() is not a constant function in the migrations`);
      return v;
    },
    sig(name) {
      const f = functions.get(name);
      if (!f) return `${name}(…)  — not found in migrations`;
      return `${name}(${f.args.replace(/\s+default\s+/gi, ' = ').replace(/::[a-z ]+/gi, '')})`;
    },
    callers(name) {
      const g = grants.get(name);
      return g && g.size ? [...g].sort().join(', ') : 'not granted';
    },
    returnCols(name) {
      const f = functions.get(name);
      const r = f && /^table \((.*)\)$/.exec(f.returns);
      if (!r) return [];
      const out = []; let depth = 0, cur = '';
      for (const c of r[1]) { if (c === '(') depth++; if (c === ')') depth--; if (c === ',' && depth === 0) { out.push(cur.trim()); cur = ''; } else cur += c; }
      out.push(cur.trim());
      return out.map((x) => { const [n, ...t] = x.split(' '); return [n, t.join(' ')]; });
    },
    enumValues(name) { return enums.get(name) ?? []; },
    checkValues(key) { return checks.get(key) ?? []; },
    columns(table) { return tables.get(table)?.columns ?? []; },
  };
}
