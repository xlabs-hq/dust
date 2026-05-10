import React from "react";
import { Head } from "@inertiajs/react";
import { Button } from "@/components/ui/Button";

function Landing() {
  return (
    <>
      <Head title="Dust — Reactive Global Map" />
      <div className="min-h-screen bg-background text-foreground">
        {/* Nav */}
        <header className="flex items-center justify-between px-6 py-4 max-w-4xl mx-auto">
          <span className="text-lg font-semibold tracking-tight">Dust</span>
          <div className="flex items-center gap-1">
            <a
              href="https://github.com/xlabs-hq/dust"
              target="_blank"
              rel="noopener noreferrer"
            >
              <Button variant="ghost" size="sm" className="gap-2">
                <svg
                  viewBox="0 0 1024 1024"
                  aria-hidden="true"
                  className="h-4 w-4"
                  fill="none"
                >
                  <path
                    fill="currentColor"
                    fillRule="evenodd"
                    clipRule="evenodd"
                    d="M512 0C229.12 0 0 229.12 0 512c0 226.56 146.56 417.92 350.08 485.76 25.6 4.48 35.2-10.88 35.2-24.32 0-12.16-.64-52.48-.64-95.36-128.64 23.68-161.92-31.36-172.16-60.16-5.76-14.72-30.72-60.16-52.48-72.32-17.92-9.6-43.52-33.28-.64-33.92 40.32-.64 69.12 37.12 78.72 52.48 46.08 77.44 119.68 55.68 149.12 42.24 4.48-33.28 17.92-55.68 32.64-68.48-113.92-12.8-232.96-56.96-232.96-252.8 0-55.68 19.84-101.76 52.48-137.6-5.12-12.8-23.04-65.28 5.12-135.68 0 0 42.88-13.44 140.8 52.48 40.96-11.52 84.48-17.28 128-17.28s87.04 5.76 128 17.28c97.92-66.56 140.8-52.48 140.8-52.48 28.16 70.4 10.24 122.88 5.12 135.68 32.64 35.84 52.48 81.28 52.48 137.6 0 196.48-119.68 240-233.6 252.8 18.56 16 34.56 46.72 34.56 94.72 0 68.48-.64 123.52-.64 140.8 0 13.44 9.6 29.44 35.2 24.32C877.44 929.92 1024 737.92 1024 512 1024 229.12 794.88 0 512 0"
                  />
                </svg>
                GitHub
              </Button>
            </a>
            <a href="/auth/login">
              <Button variant="ghost" size="sm">
                Sign in
              </Button>
            </a>
          </div>
        </header>

        {/* Hero */}
        <section className="max-w-4xl mx-auto px-6 pt-24 pb-20 text-center">
          <h1 className="text-5xl sm:text-6xl font-bold tracking-tight">
            Dust
          </h1>
          <p className="mt-4 text-xl sm:text-2xl text-muted-foreground font-medium">
            The reactive global map
          </p>
          <p className="mt-6 max-w-2xl mx-auto text-base text-muted-foreground leading-relaxed">
            Create a store, write data, subscribe to changes — every connected
            client reacts. Like Tailscale made networking disappear, Dust makes
            shared state disappear.
          </p>
          <div className="mt-10">
            <a href="/auth/login">
              <Button size="lg" className="text-base px-8">
                Get Started
              </Button>
            </a>
          </div>
        </section>

        {/* How it works */}
        <section className="max-w-4xl mx-auto px-6 py-20">
          <h2 className="text-sm font-semibold uppercase tracking-widest text-muted-foreground text-center mb-12">
            How it works
          </h2>
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-10">
            <div className="text-center">
              <div className="text-3xl mb-3">1</div>
              <h3 className="font-semibold text-lg">Create a store</h3>
              <p className="mt-2 text-sm text-muted-foreground leading-relaxed">
                Named stores with slash-separated paths. Explicit creation,
                scoped tokens, fine-grained access.
              </p>
            </div>
            <div className="text-center">
              <div className="text-3xl mb-3">2</div>
              <h3 className="font-semibold text-lg">Write data</h3>
              <p className="mt-2 text-sm text-muted-foreground leading-relaxed">
                Structured values — maps, counters, sets, decimals, datetimes,
                files. Writes queue locally and sync in the background.
              </p>
            </div>
            <div className="text-center">
              <div className="text-3xl mb-3">3</div>
              <h3 className="font-semibold text-lg">Every client reacts</h3>
              <p className="mt-2 text-sm text-muted-foreground leading-relaxed">
                Glob-pattern subscriptions fire when matching keys change. One
                write, every subscriber reacts instantly.
              </p>
            </div>
          </div>
        </section>

        {/* Code example */}
        <section className="max-w-4xl mx-auto px-6 py-20">
          <h2 className="text-sm font-semibold uppercase tracking-widest text-muted-foreground text-center mb-12">
            Simple by design
          </h2>
          <div className="rounded-lg border border-border bg-muted/30 p-6 sm:p-8 overflow-x-auto">
            <pre className="font-mono text-sm leading-relaxed text-foreground">
              <code>{`# Connect to a store
store = Dust.store("acme/config")

# Write data
Dust.put(store, "settings.theme", "dark")
Dust.put(store, "settings.lang", "en")

# Subscribe to changes
Dust.on(store, "settings.*", fn path, value ->
  IO.puts("#{path} changed to #{inspect(value)}")
end)

# Every connected client sees changes instantly`}</code>
            </pre>
          </div>
        </section>

        {/* Footer */}
        <footer className="max-w-4xl mx-auto px-6 py-12 border-t border-border">
          <p className="text-sm text-muted-foreground text-center">
            Built by{" "}
            <a
              href="https://xlabs.io"
              target="_blank"
              rel="noopener noreferrer"
              className="underline hover:text-foreground transition-colors"
            >
              xlabs.io
            </a>
          </p>
        </footer>
      </div>
    </>
  );
}

// Opt out of the Shell layout — Landing uses its own full-screen layout
Landing.layout = (page: React.ReactNode) => page;

export default Landing;
