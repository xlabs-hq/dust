import React, { useState } from "react";
import { Head, Link, usePage } from "@inertiajs/react";
import { Button } from "@/components/ui/Button";
import { Badge } from "@/components/ui/Badge";
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from "@/components/ui/Card";
import type { SharedProps } from "@/types";
import { AlertTriangle, Check, Copy } from "lucide-react";

interface TokenStore {
  id: string;
  name: string;
}

interface CreatedToken {
  id: string;
  name: string;
  store_label: string;
  store_access_mode: "all" | "selected";
  stores: TokenStore[];
  scopes: string[];
  permissions: { read: boolean; write: boolean };
}

interface TokenCreatedProps extends SharedProps {
  raw_token: string;
  token: CreatedToken;
}

export default function TokenCreated() {
  const { raw_token, token, current_organization } =
    usePage<TokenCreatedProps>().props;
  const orgSlug = current_organization?.slug || "";

  const [copied, setCopied] = useState(false);

  async function copyToken() {
    await navigator.clipboard.writeText(raw_token);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  return (
    <>
      <Head title="Token Created" />
      <div className="max-w-2xl space-y-6">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight text-foreground">
            Token Created
          </h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Your new API token has been generated
          </p>
        </div>

        <Card className="border-amber-500/50">
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-amber-600 dark:text-amber-400">
              <AlertTriangle className="h-5 w-5" />
              Copy your token now
            </CardTitle>
            <CardDescription>
              This is the only time the token value will be displayed.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="flex items-center gap-2">
              <code className="flex-1 select-all break-all rounded-md bg-muted p-3 font-mono text-sm">
                {raw_token}
              </code>
              <Button
                variant="outline"
                size="icon"
                onClick={copyToken}
                title="Copy token"
              >
                {copied ? (
                  <Check className="h-4 w-4 text-green-500" />
                ) : (
                  <Copy className="h-4 w-4" />
                )}
              </Button>
            </div>

            <div className="space-y-3 text-sm">
              <Detail label="Name" value={token.name} />
              <Detail label="Store Access" value={token.store_label} mono />
              <div className="flex items-start justify-between gap-4">
                <span className="text-muted-foreground">Scopes</span>
                <div className="flex max-w-sm flex-wrap justify-end gap-1">
                  {token.scopes.map((scope) => (
                    <Badge key={scope} variant="outline">
                      {scope}
                    </Badge>
                  ))}
                </div>
              </div>
            </div>
          </CardContent>
          <CardFooter>
            <Button asChild className="w-full">
              <Link href={`/${orgSlug}/tokens`}>Done</Link>
            </Button>
          </CardFooter>
        </Card>
      </div>
    </>
  );
}

function Detail({
  label,
  value,
  mono,
}: {
  label: string;
  value: string;
  mono?: boolean;
}) {
  return (
    <div className="flex justify-between gap-4">
      <span className="text-muted-foreground">{label}</span>
      <span className={mono ? "font-mono" : "font-medium"}>{value}</span>
    </div>
  );
}
