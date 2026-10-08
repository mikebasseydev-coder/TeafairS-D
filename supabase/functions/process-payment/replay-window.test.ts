import { assertEquals } from "jsr:@std/assert@1";
import { eventTime, withinReplayWindow } from "./replay-window.ts";

const now = new Date("2026-10-07T12:00:00Z");
const at = (iso: string) => new Date(iso);

Deno.test("±300 s is inside; 301 s either way is outside (§3.6 check 2)", () => {
  assertEquals(withinReplayWindow(at("2026-10-07T11:55:00Z"), now), true);
  assertEquals(withinReplayWindow(at("2026-10-07T12:05:00Z"), now), true);
  assertEquals(withinReplayWindow(at("2026-10-07T11:54:59Z"), now), false);
  assertEquals(withinReplayWindow(at("2026-10-07T12:05:01Z"), now), false);
});

Deno.test("paid_at is preferred, created_at is the fallback", () => {
  assertEquals(eventTime({ paid_at: "2026-10-07T11:59:00Z", created_at: "2026-10-07T10:00:00Z" })?.toISOString(),
    "2026-10-07T11:59:00.000Z");
  assertEquals(eventTime({ paid_at: null, created_at: "2026-10-07T10:00:00Z" })?.toISOString(),
    "2026-10-07T10:00:00.000Z");
});

Deno.test("no usable time fails closed", () => {
  assertEquals(eventTime({}), null);
  assertEquals(eventTime({ paid_at: "not a date" }), null);
  assertEquals(withinReplayWindow(null, now), false);
});
