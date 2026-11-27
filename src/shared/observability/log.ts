// The only logger (Spec B §4.4). Every message and context goes through scrub.
import { scrubString, scrubValue } from "./scrub";

export type LogLevel = "debug" | "info" | "warn" | "error";
export type LogSink = (level: LogLevel, message: string, context?: unknown) => void;

/* eslint-disable no-console */
const consoleSink: LogSink = (level, message, context) => {
  const fn = level === "error" ? console.error : level === "warn" ? console.warn : console.log;
  if (context === undefined) fn(`[${level}] ${message}`);
  else fn(`[${level}] ${message}`, context);
};
/* eslint-enable no-console */

let sink: LogSink = consoleSink;

/** Tests and the future error reporter replace the sink; nothing else writes logs. */
export function setLogSink(next: LogSink): void {
  sink = next;
}

function emit(level: LogLevel, message: string, context?: unknown) {
  sink(level, scrubString(message), context === undefined ? undefined : scrubValue(context));
}

export const log = {
  debug: (message: string, context?: unknown) => emit("debug", message, context),
  info: (message: string, context?: unknown) => emit("info", message, context),
  warn: (message: string, context?: unknown) => emit("warn", message, context),
  error: (message: string, context?: unknown) => emit("error", message, context),
};
