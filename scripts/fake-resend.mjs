// A fake Resend for the Playwright app run (Spec B §11): the local
// send-auth-email hook posts its sign-in emails here instead of to Resend, and
// the tests read the code back. Test target only. It listens on every
// interface, because the edge runtime (Docker) reaches it at
// host.docker.internal.
//   POST /emails          what Resend's API takes; recorded, answered 200
//   GET  /__emails?to=x   the emails sent to x, newest last
import { createServer } from "node:http";

const port = Number(process.env.FAKE_RESEND_PORT ?? 8097);
const sent = [];

createServer((req, res) => {
  const url = new URL(req.url ?? "/", "http://localhost");
  if (req.method === "GET" && url.pathname === "/") return void res.writeHead(200).end("fake resend");
  if (req.method === "GET" && url.pathname === "/__emails") {
    const to = (url.searchParams.get("to") ?? "").toLowerCase();
    const mine = sent.filter((e) => e.to.includes(to));
    res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(mine));
    return;
  }
  if (req.method === "POST" && url.pathname === "/emails") {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      try {
        const e = JSON.parse(body);
        sent.push({ to: (e.to ?? []).map((t) => String(t).toLowerCase()), subject: e.subject, text: e.text, at: Date.now() });
        res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ id: `fake-${sent.length}` }));
      } catch {
        res.writeHead(400).end();
      }
    });
    return;
  }
  res.writeHead(404).end();
}).listen(port, "0.0.0.0", () => console.log(`fake resend on ${port}`));
