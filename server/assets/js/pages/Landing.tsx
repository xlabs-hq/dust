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
          <a href="/auth/login">
            <Button variant="ghost" size="sm">
              Sign in
            </Button>
          </a>
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
                Named stores with slash-separated paths. Explicit creation, scoped tokens, fine-grained access.
              </p>
            </div>
            <div className="text-center">
              <div className="text-3xl mb-3">2</div>
              <h3 className="font-semibold text-lg">Write data</h3>
              <p className="mt-2 text-sm text-muted-foreground leading-relaxed">
                Structured values — maps, counters, sets, decimals, datetimes, files. Writes queue locally and sync in the background.
              </p>
            </div>
            <div className="text-center">
              <div className="text-3xl mb-3">3</div>
              <h3 className="font-semibold text-lg">Every client reacts</h3>
              <p className="mt-2 text-sm text-muted-foreground leading-relaxed">
                Glob-pattern subscriptions fire when matching keys change. One write, every subscriber reacts instantly.
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
            Built by James
          </p>
        </footer>
      </div>
    </>
  );
}

// Opt out of the Shell layout — Landing uses its own full-screen layout
Landing.layout = (page: React.ReactNode) => page;

export default Landing;
