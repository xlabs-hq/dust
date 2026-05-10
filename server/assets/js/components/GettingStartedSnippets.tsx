import React, { useState } from "react";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/Tabs";
import { Button } from "@/components/ui/Button";
import { Check, Copy } from "lucide-react";

interface Props {
  storeFullName: string;
  orgSlug: string;
}

export default function GettingStartedSnippets({
  storeFullName,
  orgSlug,
}: Props) {
  const origin =
    typeof window !== "undefined" ? window.location.origin : "https://dustlayer.io";
  const wsOrigin = origin.replace(/^http/, "ws");

  return (
    <div className="rounded-lg border border-dashed p-6">
      <h3 className="text-base font-medium text-foreground">
        Connect a client
      </h3>
      <p className="text-sm text-muted-foreground mt-1">
        Pick a stack and copy a snippet. You'll need a token with write access —{" "}
        <a
          href={`/${orgSlug}/tokens/new`}
          className="underline underline-offset-4 hover:text-foreground"
        >
          create one
        </a>
        .
      </p>

      <div className="mt-4">
        <Tabs defaultValue="curl">
          <TabsList>
            <TabsTrigger value="curl">curl</TabsTrigger>
            <TabsTrigger value="ts">TypeScript</TabsTrigger>
            <TabsTrigger value="elixir">Elixir</TabsTrigger>
            <TabsTrigger value="cli">CLI</TabsTrigger>
          </TabsList>

          <TabsContent value="curl">
            <Snippet
              code={`curl -X PUT \\
  ${origin}/api/stores/${storeFullName}/entries/hello \\
  -H "Authorization: Bearer dust_tok_…" \\
  -H "Content-Type: application/json" \\
  -d '"world"'`}
            />
            <p className="text-xs text-muted-foreground mt-3">
              Paths in the URL use slashes;{" "}
              <code className="font-mono">/entries/projects/alpha/title</code>{" "}
              writes the canonical key{" "}
              <code className="font-mono">projects.alpha.title</code>.
            </p>
          </TabsContent>

          <TabsContent value="ts">
            <Snippet
              code={`import { Dust } from "@dustlayer/dust";

const dust = new Dust({
  url: "${wsOrigin}/ws/sync",
  token: "dust_tok_…",
});

await dust.put("${storeFullName}", "hello", "world");
dust.on("${storeFullName}", "**", (path, value) => {
  console.log("changed:", path, value);
});`}
            />
          </TabsContent>

          <TabsContent value="elixir">
            <Snippet
              code={`# mix.exs
{:dust, "~> 0.1"}

# In your supervision tree:
{Dust.Supervisor,
  url: "${wsOrigin}/ws/sync",
  token: System.get_env("DUST_TOKEN"),
  stores: ["${storeFullName}"],
  cache: {Dust.Cache.Memory, []}}

# Then anywhere:
Dust.put("${storeFullName}", "hello", "world")
Dust.on("${storeFullName}", "**", fn path, value ->
  IO.inspect({path, value}, label: "changed")
end)`}
            />
          </TabsContent>

          <TabsContent value="cli">
            <Snippet
              code={`brew install xlabs-hq/dust/dust   # or download from GitHub releases
dust auth login
dust put ${storeFullName} hello '"world"'
dust watch ${storeFullName} '**'`}
            />
          </TabsContent>
        </Tabs>
      </div>
    </div>
  );
}

function Snippet({ code }: { code: string }) {
  const [copied, setCopied] = useState(false);

  const onCopy = async () => {
    try {
      await navigator.clipboard.writeText(code);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      /* clipboard unavailable — silent */
    }
  };

  return (
    <div className="relative">
      <pre className="mt-3 rounded-md bg-muted p-4 text-xs font-mono overflow-x-auto">
        {code}
      </pre>
      <Button
        variant="ghost"
        size="sm"
        className="absolute top-2 right-2 h-7 px-2 gap-1.5 text-xs"
        onClick={onCopy}
      >
        {copied ? (
          <>
            <Check className="w-3.5 h-3.5" /> Copied
          </>
        ) : (
          <>
            <Copy className="w-3.5 h-3.5" /> Copy
          </>
        )}
      </Button>
    </div>
  );
}
