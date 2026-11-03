// A small document renderer over pdfkit: title page, a table of contents
// with real page numbers, numbered headings, rich paragraphs (**bold**,
// `code`), bullets, tables, callouts and code blocks, then running headers
// and footers on every page after the title.
import fs from 'node:fs';
import PDFDocument from 'pdfkit';

export const PALETTE = {
  navy: '#0F2A44',
  navySoft: '#1E3A5F',
  teal: '#0F766E',
  tealSoft: '#CCEDE9',
  tealTint: '#EEF8F6',
  slate900: '#1E293B',
  slate700: '#334155',
  slate500: '#64748B',
  slate300: '#CBD5E1',
  slate100: '#F1F5F9',
  white: '#FFFFFF',
  amber: '#B45309',
  amberTint: '#FEF6E7',
  red: '#B91C1C',
  redTint: '#FDEEEE',
};

const WIN_FONTS = 'C:/Windows/Fonts/';
const FONT_CANDIDATES = {
  body: [process.env.REPORT_FONT_BODY, `${WIN_FONTS}segoeui.ttf`, `${WIN_FONTS}arial.ttf`],
  bold: [process.env.REPORT_FONT_BOLD, `${WIN_FONTS}segoeuib.ttf`, `${WIN_FONTS}arialbd.ttf`],
  mono: [process.env.REPORT_FONT_MONO, `${WIN_FONTS}consola.ttf`],
};

function pick(list) {
  return list.find((p) => p && fs.existsSync(p)) ?? null;
}

const PAGE = { size: 'A4', margin: 56 };
const HEADER_H = 30;

export class Report {
  constructor({ file, title, subtitle, docId, version, date, classification, meta }) {
    this.file = file;
    this.info = { title, subtitle, docId, version, date, classification };
    this.doc = new PDFDocument({
      size: PAGE.size,
      margins: { top: PAGE.margin + HEADER_H, bottom: PAGE.margin + 10, left: PAGE.margin, right: PAGE.margin },
      bufferPages: true,
      autoFirstPage: false,
      info: { Title: title, Subject: subtitle, Author: 'Teafair Systems Architecture', Keywords: meta ?? '' },
    });
    this.stream = fs.createWriteStream(file);
    this.doc.pipe(this.stream);

    const body = pick(FONT_CANDIDATES.body);
    const bold = pick(FONT_CANDIDATES.bold);
    const mono = pick(FONT_CANDIDATES.mono);
    this.unicode = Boolean(body && bold);
    this.doc.registerFont('body', body ?? 'Helvetica');
    this.doc.registerFont('bold', bold ?? 'Helvetica-Bold');
    this.doc.registerFont('mono', mono ?? 'Courier');
    this.monoUnicode = Boolean(mono);

    this.headings = [];
    this.counters = [0, 0, 0];
    this.figure = 0;
    this.tableNo = 0;
  }

  // Fonts without the naira sign or arrows fall back to ASCII.
  t(s, mono = false) {
    const s2 = String(s);
    if (mono ? this.monoUnicode : this.unicode) return s2;
    return s2.replace(/₦/g, 'NGN ').replace(/→/g, '->').replace(/≤/g, '<=').replace(/≥/g, '>=')
      .replace(/—/g, '-').replace(/–/g, '-').replace(/[“”]/g, '"').replace(/[‘’]/g, "'").replace(/·/g, '-');
  }

  get W() { return this.doc.page.width - this.doc.page.margins.left - this.doc.page.margins.right; }
  get L() { return this.doc.page.margins.left; }
  get bottom() { return this.doc.page.height - this.doc.page.margins.bottom; }

  ensure(h) {
    if (this.doc.y + h > this.bottom) this.doc.addPage();
  }

  // ── title page ───────────────────────────────────────────────────────
  titlePage({ kicker, highlights, scopeLines }) {
    const d = this.doc;
    d.addPage({ margins: { top: 0, bottom: 0, left: 0, right: 0 } });
    const w = d.page.width, h = d.page.height;
    d.rect(0, 0, w, h * 0.58).fill(PALETTE.navy);
    d.rect(0, h * 0.58, w, 6).fill(PALETTE.teal);
    // a quiet grid motif
    d.save().opacity(0.07);
    for (let x = 0; x < w; x += 28) d.moveTo(x, 0).lineTo(x, h * 0.58).lineWidth(0.6).stroke(PALETTE.white);
    for (let y = 0; y < h * 0.58; y += 28) d.moveTo(0, y).lineTo(w, y).lineWidth(0.6).stroke(PALETTE.white);
    d.restore();

    const x = 64;
    d.font('bold').fontSize(10).fillColor(PALETTE.tealSoft)
      .text(this.t(kicker.toUpperCase()), x, 92, { characterSpacing: 2.2, width: w - 128 });
    d.font('bold').fontSize(30).fillColor(PALETTE.white)
      .text(this.t(this.info.title), x, 128, { width: w - 128, lineGap: 4 });
    d.moveDown(0.6);
    d.font('body').fontSize(13).fillColor('#C9D6E3').text(this.t(this.info.subtitle), { width: w - 150, lineGap: 3 });

    // meta block
    const metaY = h * 0.58 - 92;
    const meta = [
      ['Document', this.info.docId], ['Version', this.info.version],
      ['Date', this.info.date], ['Classification', this.info.classification],
    ];
    meta.forEach(([k, v], i) => {
      const mx = x + i * ((w - 128) / 4);
      d.font('body').fontSize(8).fillColor('#8FA6BD').text(k.toUpperCase(), mx, metaY, { characterSpacing: 1 });
      d.font('bold').fontSize(10.5).fillColor(PALETTE.white).text(this.t(v), mx, metaY + 14, { width: (w - 128) / 4 - 8 });
    });

    // lower half: scope and highlights
    let y = h * 0.58 + 44;
    d.font('bold').fontSize(11).fillColor(PALETTE.teal).text('SCOPE OF THIS DOCUMENT', x, y, { characterSpacing: 1.2 });
    y += 22;
    d.font('body').fontSize(10.5).fillColor(PALETTE.slate700);
    for (const line of scopeLines) {
      d.text(this.t(line), x, y, { width: w - 128, lineGap: 2 });
      y = d.y + 6;
    }
    y += 10;
    const colW = (w - 128 - 24) / highlights.length;
    highlights.forEach(([num, label], i) => {
      const hx = x + i * (colW + 12);
      d.rect(hx, y, colW, 64).fill(PALETTE.slate100);
      d.rect(hx, y, 3, 64).fill(PALETTE.teal);
      d.font('bold').fontSize(18).fillColor(PALETTE.navy).text(this.t(num), hx + 14, y + 12, { width: colW - 20 });
      d.font('body').fontSize(8.5).fillColor(PALETTE.slate500).text(this.t(label), hx + 14, y + 38, { width: colW - 20 });
    });

    d.font('body').fontSize(8).fillColor(PALETTE.slate500)
      .text(this.t('Teafair · Multi-tenant Route-to-Market and embedded liquidity platform · Generated from supabase/migrations by docs/reports/generator'),
        x, h - 54, { width: w - 128, align: 'left' });
  }

  // ── table of contents (pages reserved now, filled at the end) ────────
  reserveToc(entryCount) {
    const perPage = 34;
    this.tocPages = Math.max(1, Math.ceil((entryCount + 3) / perPage));
    this.tocStart = this.doc.bufferedPageRange().count;
    for (let i = 0; i < this.tocPages; i++) this.doc.addPage();
  }

  fillToc() {
    if (this.tocStart === undefined) return;
    const d = this.doc;
    let page = this.tocStart;
    d.switchToPage(page);
    d.y = d.page.margins.top;
    d.font('bold').fontSize(22).fillColor(PALETTE.navy).text('Contents', this.L, d.y);
    d.moveDown(0.8);
    for (const hd of this.headings) {
      if (d.y > this.bottom - 20) { page += 1; d.switchToPage(page); d.y = d.page.margins.top; }
      const y = d.y;
      const indent = hd.level === 1 ? 0 : 18;
      const size = hd.level === 1 ? 11 : 9.5;
      d.font(hd.level === 1 ? 'bold' : 'body').fontSize(size).fillColor(hd.level === 1 ? PALETTE.slate900 : PALETTE.slate700);
      const label = `${hd.num}  ${hd.title}`;
      const pageLabel = String(hd.page + 1);
      const pw = d.widthOfString(pageLabel);
      d.text(this.t(label), this.L + indent, y, { width: this.W - indent - pw - 30, lineBreak: false, ellipsis: true, goTo: hd.anchor });
      const tw = Math.min(d.widthOfString(this.t(label)), this.W - indent - pw - 30);
      // leader dots
      d.save().fillColor(PALETTE.slate300);
      for (let x = this.L + indent + tw + 6; x < this.L + this.W - pw - 8; x += 4) d.circle(x, y + size * 0.72, 0.5).fill();
      d.restore();
      d.fillColor(PALETTE.slate700).text(pageLabel, this.L + this.W - pw, y, { lineBreak: false });
      d.y = y + (hd.level === 1 ? 21 : 16);
      if (hd.level === 1) d.y += 2;
    }
  }

  // ── headings ─────────────────────────────────────────────────────────
  h1(title, { newPage = true } = {}) {
    const d = this.doc;
    if (newPage) d.addPage(); else this.ensure(90);
    this.counters[0] += 1; this.counters[1] = 0; this.counters[2] = 0;
    const num = `${this.counters[0]}.`;
    const anchor = `h-${this.counters[0]}`;
    d.addNamedDestination(anchor);
    this.headings.push({ level: 1, num, title, page: d.bufferedPageRange().start + d.bufferedPageRange().count - 1, anchor });
    const y = d.y;
    d.font('bold').fontSize(11).fillColor(PALETTE.teal).text(`SECTION ${this.counters[0]}`, this.L, y, { characterSpacing: 1.5 });
    d.font('bold').fontSize(21).fillColor(PALETTE.navy).text(this.t(title), this.L, d.y + 4, { width: this.W });
    d.moveTo(this.L, d.y + 6).lineTo(this.L + 54, d.y + 6).lineWidth(2.5).stroke(PALETTE.teal);
    d.y += 20;
  }

  h2(title) {
    const d = this.doc;
    this.ensure(70);
    this.counters[1] += 1; this.counters[2] = 0;
    const num = `${this.counters[0]}.${this.counters[1]}`;
    const anchor = `h-${num}`;
    d.addNamedDestination(anchor);
    this.headings.push({ level: 2, num, title, page: d.bufferedPageRange().count - 1, anchor });
    d.moveDown(0.5);
    d.font('bold').fontSize(13.5).fillColor(PALETTE.navySoft).text(this.t(`${num}  ${title}`), this.L, d.y, { width: this.W });
    d.moveDown(0.35);
  }

  h3(title) {
    const d = this.doc;
    this.ensure(50);
    d.moveDown(0.3);
    d.font('bold').fontSize(10.5).fillColor(PALETTE.teal).text(this.t(title), this.L, d.y, { width: this.W });
    d.moveDown(0.2);
  }

  // ── text ─────────────────────────────────────────────────────────────
  // **bold** and `code` inline.
  rich(text, { x = this.L, width = this.W, size = 10, color = PALETTE.slate700, lineGap = 2.2, indent = 0 } = {}) {
    const d = this.doc;
    const parts = String(text).split(/(\*\*[^*]+\*\*|`[^`]+`)/g).filter((p) => p !== '');
    d.fillColor(color);
    d.x = x;
    // pdfkit keeps one line wrapper across `continued` calls: only the first
    // call may set the position and width; later calls pass options only.
    parts.forEach((p, i) => {
      const last = i === parts.length - 1;
      let str, font, fsize, fill;
      if (p.startsWith('**')) { str = this.t(p.slice(2, -2)); font = 'bold'; fsize = size; fill = PALETTE.slate900; }
      else if (p.startsWith('`')) { str = this.t(p.slice(1, -1), true); font = 'body'; fsize = size; fill = PALETTE.teal; } // pdfkit aligns continued runs by ascent, so a mono run would sit high; inline code is marked by colour
      else { str = this.t(p); font = 'body'; fsize = size; fill = color; }
      d.font(font).fontSize(fsize).fillColor(fill);
      if (i === 0) d.text(str, x, d.y, { width, lineGap, continued: !last, indent });
      else d.text(str, { continued: !last });
    });
  }

  p(text, opts = {}) {
    this.ensure(30);
    this.rich(text, opts);
    this.doc.moveDown(0.55);
  }

  bullets(items, { marker = '•', size = 10 } = {}) {
    const d = this.doc;
    for (const it of items) {
      this.ensure(22);
      const y = d.y;
      const isNum = marker === '1';
      const m = isNum ? `${items.indexOf(it) + 1}.` : marker;
      d.font(isNum ? 'bold' : 'body').fontSize(size).fillColor(PALETTE.teal).text(m, this.L + 4, y, { lineBreak: false });
      this.rich(it, { x: this.L + 20, width: this.W - 20, size });
      d.moveDown(0.25);
    }
    d.moveDown(0.3);
  }

  // ── callouts ─────────────────────────────────────────────────────────
  callout(kind, title, body) {
    const d = this.doc;
    const tone = {
      note: [PALETTE.teal, PALETTE.tealTint],
      warn: [PALETTE.amber, PALETTE.amberTint],
      finding: [PALETTE.red, PALETTE.redTint],
      rule: [PALETTE.navy, PALETTE.slate100],
    }[kind];
    const pad = 12;
    const innerW = this.W - pad * 2 - 4;
    const lines = Array.isArray(body) ? body : [body];
    d.font('body').fontSize(9.5);
    const textH = lines.reduce((acc, l) => acc + d.heightOfString(this.t(l.replace(/\*\*|`/g, '')), { width: innerW, lineGap: 2 }) + 4, 0);
    const h = textH + pad * 2 + 16;
    this.ensure(Math.min(h, 400));
    const y0 = d.y;
    d.rect(this.L, y0, this.W, h).fill(tone[1]);
    d.rect(this.L, y0, 4, h).fill(tone[0]);
    d.font('bold').fontSize(9).fillColor(tone[0]).text(this.t(title.toUpperCase()), this.L + pad + 4, y0 + pad, { characterSpacing: 1, width: innerW });
    d.y = y0 + pad + 16;
    for (const l of lines) {
      this.rich(l, { x: this.L + pad + 4, width: innerW, size: 9.5, color: PALETTE.slate900 });
      d.y += 4;
    }
    d.y = Math.max(d.y, y0 + h) + 10;
    d.x = this.L;
  }

  // ── tables ───────────────────────────────────────────────────────────
  table(headers, rows, { widths, size = 8.8, mono = [] , caption } = {}) {
    const d = this.doc;
    const W = this.W;
    const ws = (widths ?? headers.map(() => 1 / headers.length)).map((f) => f * W);
    const pad = 5;
    const cellFont = (ci) => (mono.includes(ci) ? 'mono' : 'body');
    const cellSize = (ci) => (mono.includes(ci) ? size - 0.8 : size);
    const strip = (s) => String(s ?? '').replace(/\*\*/g, '').replace(/`/g, '');
    const rowH = (cells, font) => Math.max(...cells.map((c, ci) => {
      d.font(font ?? cellFont(ci)).fontSize(font ? size : cellSize(ci));
      return d.heightOfString(this.t(strip(c), mono.includes(ci)), { width: ws[ci] - pad * 2, lineGap: 1 });
    })) + pad * 2;

    const drawHeader = () => {
      const hh = rowH(headers, 'bold');
      const y = d.y;
      d.rect(this.L, y, W, hh).fill(PALETTE.navy);
      let x = this.L;
      headers.forEach((h, ci) => {
        d.font('bold').fontSize(size).fillColor(PALETTE.white).text(this.t(h), x + pad, y + pad, { width: ws[ci] - pad * 2, lineGap: 1 });
        x += ws[ci];
      });
      d.y = y + hh;
    };

    this.ensure(rowH(headers, 'bold') + (rows[0] ? rowH(rows[0]) : 0) + 4);
    drawHeader();
    rows.forEach((r, ri) => {
      const h = rowH(r);
      if (d.y + h > this.bottom) { d.addPage(); drawHeader(); }
      const y = d.y;
      if (ri % 2 === 1) d.rect(this.L, y, W, h).fill(PALETTE.slate100);
      let x = this.L;
      r.forEach((c, ci) => {
        const isBold = String(c ?? '').startsWith('**');
        d.font(isBold ? 'bold' : cellFont(ci)).fontSize(cellSize(ci))
          .fillColor(mono.includes(ci) ? PALETTE.navySoft : PALETTE.slate900)
          .text(this.t(strip(c), mono.includes(ci)), x + pad, y + pad, { width: ws[ci] - pad * 2, lineGap: 1 });
        x += ws[ci];
      });
      d.moveTo(this.L, y + h).lineTo(this.L + W, y + h).lineWidth(0.4).stroke(PALETTE.slate300);
      d.y = y + h;
    });
    d.x = this.L;
    if (caption) {
      this.tableNo += 1;
      d.moveDown(0.3);
      d.font('body').fontSize(8).fillColor(PALETTE.slate500).text(this.t(`Table ${this.tableNo}. ${caption.replace(/`/g, '')}`), this.L, d.y, { width: W });
    }
    d.moveDown(0.8);
  }

  // ── code ─────────────────────────────────────────────────────────────
  code(text, { size = 8 } = {}) {
    const d = this.doc;
    const pad = 10;
    const lines = String(text).replace(/\t/g, '  ').split('\n');
    d.font('mono').fontSize(size);
    const lineH = d.currentLineHeight(true) + 1.2;
    let i = 0;
    while (i < lines.length) {
      this.ensure(lineH * 3 + pad * 2);
      const room = Math.floor((this.bottom - d.y - pad * 2) / lineH);
      const chunk = [];
      let used = 0;
      while (i < lines.length && used < room) {
        const ln = this.t(lines[i], true);
        const h = d.heightOfString(ln || ' ', { width: this.W - pad * 2 });
        const n = Math.max(1, Math.round(h / (d.currentLineHeight(true))));
        if (used + n > room && chunk.length) break;
        chunk.push(ln); used += n; i += 1;
      }
      const h = used * lineH + pad * 2;
      const y0 = d.y;
      d.rect(this.L, y0, this.W, h).fill('#0B1F33');
      d.fillColor('#D6E4F0');
      let y = y0 + pad;
      for (const ln of chunk) {
        d.text(ln || ' ', this.L + pad, y, { width: this.W - pad * 2, lineGap: 1.2 });
        y = d.y;
      }
      d.y = y0 + h + 8;
      if (i < lines.length) d.addPage();
    }
    d.x = this.L;
    d.moveDown(0.3);
  }

  // ── a two-column definition list ─────────────────────────────────────
  kv(pairs, { keyW = 0.28 } = {}) {
    this.table(['Item', 'Value'], pairs, { widths: [keyW, 1 - keyW] });
  }

  // A simple horizontal flow diagram drawn with boxes and arrows.
  flow(rawSteps, { caption } = {}) {
    const d = this.doc;
    const steps = rawSteps.map(([t, s]) => [t.replace(/`/g, ''), s ? s.replace(/`/g, '').replace(/_/g, '_​') : s]);
    const n = steps.length;
    const gap = 16;
    const bw = (this.W - gap * (n - 1)) / n;
    const hTitle = (t) => d.font('bold').fontSize(8.5).heightOfString(this.t(t), { width: bw - 12 });
    const hSub = (s) => (s ? d.font('body').fontSize(7.5).heightOfString(this.t(s), { width: bw - 12 }) + 2 : 0);
    const bh = Math.max(...steps.map(([t, s]) => hTitle(t) + hSub(s))) + 20;
    this.ensure(bh + 30);
    const y = d.y;
    steps.forEach(([title, sub], i) => {
      const x = this.L + i * (bw + gap);
      d.roundedRect(x, y, bw, bh, 4).fill(i === n - 1 ? PALETTE.teal : PALETTE.navy);
      d.font('bold').fontSize(8.5).fillColor(PALETTE.white).text(this.t(title), x + 6, y + 8, { width: bw - 12, align: 'center' });
      if (sub) d.font('body').fontSize(7.5).fillColor('#C9D6E3').text(this.t(sub), x + 6, d.y + 2, { width: bw - 12, align: 'center' });
      if (i < n - 1) {
        const ax = x + bw + 2, ay = y + bh / 2;
        d.moveTo(ax, ay).lineTo(ax + gap - 6, ay).lineWidth(1.2).stroke(PALETTE.slate500);
        d.moveTo(ax + gap - 6, ay - 3).lineTo(ax + gap - 2, ay).lineTo(ax + gap - 6, ay + 3).fill(PALETTE.slate500);
      }
    });
    d.y = y + bh + 6;
    d.x = this.L;
    if (caption) {
      this.figure += 1;
      d.font('body').fontSize(8).fillColor(PALETTE.slate500).text(this.t(`Figure ${this.figure}. ${caption.replace(/`/g, '')}`), this.L, d.y, { width: this.W });
    }
    d.moveDown(0.8);
  }

  // ── running header and footer ────────────────────────────────────────
  finish() {
    this.fillToc();
    const d = this.doc;
    const range = d.bufferedPageRange();
    const total = range.count;
    for (let i = 1; i < total; i++) {
      d.switchToPage(i);
      const { width, height } = d.page;
      const saved = d.page.margins;
      d.page.margins = { top: 0, bottom: 0, left: 0, right: 0 };
      const m = PAGE.margin;
      d.rect(0, 0, width, 4).fill(PALETTE.teal);
      d.font('bold').fontSize(8).fillColor(PALETTE.navy).text('TEAFAIR', m, m - 14, { lineBreak: false, characterSpacing: 1.5 });
      d.font('body').fontSize(8).fillColor(PALETTE.slate500)
        .text(this.t(this.info.title), m + 54, m - 14, { width: width - 2 * m - 54, align: 'right', lineBreak: false, ellipsis: true });
      d.moveTo(m, m + 2).lineTo(width - m, m + 2).lineWidth(0.5).stroke(PALETTE.slate300);
      d.moveTo(m, height - m + 14).lineTo(width - m, height - m + 14).lineWidth(0.5).stroke(PALETTE.slate300);
      d.font('body').fontSize(7.5).fillColor(PALETTE.slate500)
        .text(this.t(`${this.info.docId} · v${this.info.version} · ${this.info.classification}`), m, height - m + 22, { lineBreak: false });
      d.text(`Page ${i + 1} of ${total}`, width - m - 80, height - m + 22, { width: 80, align: 'right', lineBreak: false });
      d.page.margins = saved;
    }
    d.end();
    return new Promise((resolve, reject) => { this.stream.on('finish', resolve); this.stream.on('error', reject); });
  }
}
