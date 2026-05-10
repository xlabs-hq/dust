/**
 * Dev-only client-error reporter.
 *
 * Captures uncaught errors, unhandled promise rejections, and console.error
 * calls, then POSTs them to /_dev/client_error so they show up in the
 * Phoenix log (and via tidewave). Stripped from prod bundles by the
 * import.meta.env.DEV gate at the call site.
 */

type Level = "error" | "warn";

const ENDPOINT = "/_dev/client_error";

function send(level: Level, message: string, stack?: string) {
  const payload = JSON.stringify({
    level,
    message,
    stack,
    url: window.location.href,
  });

  // Prefer sendBeacon when the page is unloading; otherwise fetch
  // with keepalive so unload-time errors still ship.
  try {
    if (navigator.sendBeacon) {
      const blob = new Blob([payload], { type: "application/json" });
      if (navigator.sendBeacon(ENDPOINT, blob)) return;
    }
  } catch {
    // fall through to fetch
  }

  fetch(ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: payload,
    keepalive: true,
  }).catch(() => {
    // swallow — never let the reporter itself throw
  });
}

function formatReason(reason: unknown): { message: string; stack?: string } {
  if (reason instanceof Error) {
    return { message: reason.message || String(reason), stack: reason.stack };
  }
  if (typeof reason === "object" && reason !== null) {
    try {
      return { message: JSON.stringify(reason) };
    } catch {
      return { message: String(reason) };
    }
  }
  return { message: String(reason) };
}

export function installDevErrorReporter() {
  window.addEventListener("error", (e) => {
    const { message, stack } = formatReason(e.error ?? e.message);
    send("error", message, stack);
  });

  window.addEventListener("unhandledrejection", (e) => {
    const { message, stack } = formatReason(e.reason);
    send("error", `unhandled rejection: ${message}`, stack);
  });

  // Tee console.error so React's "Objects are not valid as a React child"
  // and friends make it back to the server log too.
  const original = console.error.bind(console);
  console.error = (...args: unknown[]) => {
    original(...args);
    try {
      const message = args
        .map((a) =>
          a instanceof Error ? a.message : typeof a === "string" ? a : safe(a),
        )
        .join(" ");
      const stack = args.find((a): a is Error => a instanceof Error)?.stack;
      send("error", message, stack);
    } catch {
      // never let the shim itself error
    }
  };
}

function safe(v: unknown): string {
  try {
    return JSON.stringify(v);
  } catch {
    return String(v);
  }
}
