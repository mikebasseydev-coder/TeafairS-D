// Builds both audit PDFs into docs/reports/ from the local migrations.
//   cd docs/reports/generator && npm install && npm run build
// Fonts: Segoe UI / Consolas from C:\Windows\Fonts when present (they carry
// the naira sign); override with REPORT_FONT_BODY, REPORT_FONT_BOLD and
// REPORT_FONT_MONO, or fall back to the PDF base fonts (₦ becomes "NGN").
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { Report } from './lib/render.mjs';
import { loadSchema } from './lib/schema.mjs';
import { buildMobile } from './content/mobile.mjs';
import { buildWeb } from './content/web.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
const outDir = path.resolve(here, '..');
const schema = loadSchema(root);

const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Africa/Lagos' });
const version = '1.0';

// Render once into a throwaway report to learn the headings, so the table
// of contents can reserve the right number of pages up front.
async function countHeadings(build) {
  const tmp = path.join(outDir, `.probe-${process.pid}.pdf`);
  const probe = new Report({ file: tmp, title: 'probe', subtitle: '', docId: '', version, date: today, classification: '' });
  probe.doc.addPage();
  build(probe, schema);
  const n = probe.headings.length;
  await probe.finish();
  fs.rmSync(tmp, { force: true });
  return n;
}

async function make({ file, title, subtitle, docId, kicker, scope, highlights, build }) {
  const n = await countHeadings(build);
  const r = new Report({
    file: path.join(outDir, file), title, subtitle, docId, version, date: today,
    classification: 'Internal — Confidential', meta: 'Teafair, Monvelo, Supabase, audit, specification',
  });
  r.titlePage({ kicker, scopeLines: scope, highlights });
  r.reserveToc(n);
  build(r, schema);
  const pages = r.doc.bufferedPageRange().count;
  await r.finish();
  const kb = Math.round(fs.statSync(path.join(outDir, file)).size / 1024);
  console.log(`${file}: ${pages} pages, ${r.headings.length} headings, ${kb} KB${r.unicode ? '' : ' (base fonts: ₦ rendered as NGN)'}`);
}

const stats = [
  [String(schema.files.length), 'migrations read'],
  [String(schema.functions.size), 'SQL functions parsed'],
  [schema.tests.assertions.toLocaleString('en-US'), 'pgTAP assertions'],
];

await make({
  file: 'Teafair_Mobile_App_Audit_and_Frontend_Specification.pdf',
  title: 'Teafair Mobile App — Audit and Front-End Specification',
  subtitle: 'React Native (Expo) client for field sales, shop owners and Monvelo agents: authentication, role workspaces, the market-maker allowance, exposure and reconciliation.',
  docId: 'TF-RPT-MOB-001',
  kicker: 'Systems architecture · Audit report',
  scope: [
    `Audits the backend at migration ${schema.latest.slice(0, 14)} (A6 §20, R78) and specifies the mobile client that will consume it.`,
    'An input to Spec B, not Spec B. Items marked Proposal need the owner\'s decision; everything else is quoted from the schema and the approved specs.',
  ],
  highlights: stats,
  build: buildMobile,
});

await make({
  file: 'Teafairweb_Enterprise_Portal_Audit_and_Design_Specification.pdf',
  title: 'Teafairweb and Web Consoles — Audit and Design Specification',
  subtitle: 'The public retail storefront, the tenant operations console and settlement governance, with Monvelo oversight kept in its own domain.',
  docId: 'TF-RPT-WEB-001',
  kicker: 'Systems architecture · Audit report',
  scope: [
    `Audits the web-facing backend at migration ${schema.latest.slice(0, 14)}: public gateways, routing, pricing, NAFDAC, stock, fulfilment, the Paystack money loop and commission release.`,
    'Applies A6 §15: web never touches Monvelo. Lender oversight is specified as a separate console.',
  ],
  highlights: [[String(schema.edgeFunctions.length), 'Edge Functions'], [String(schema.cron.size), 'scheduled jobs'], ...stats.slice(0, 1)],
  build: buildWeb,
});
