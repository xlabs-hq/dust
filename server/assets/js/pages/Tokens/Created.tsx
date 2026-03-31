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
import { Check, Copy, AlertTriangle } from "lucide-react";

interface CreatedToken {
  id: string;
  name: string;
  store_name: string;
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
      <div className="space-y-6 max-w-lg">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight text-foreground">
            Token Created
          </h1>
          <p className="text-sm text-muted-foreground mt-1">
            Your new API token has been generated
          </p>
        </div>

        <Card className="border-amber-500/50">
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-amber-600 dark:text-amber-400">
              <AlertTriangle className="w-5 h-5" />
              Copy your token now
            </CardTitle>
            <CardDescription>
              This is the only time the token value will be displayed. Store it
              somewhere safe.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="flex items-center gap-2">
              <code className="flex-1 rounded-md bg-muted p-3 font-mono text-sm break-all select-all">
                {raw_token}
              </code>
              <Button
                variant="outline"
                size="icon"
                onClick={copyToken}
                title="Copy token"
              >
                {copied ? (
                  <Check className="w-4 h-4 text-green-500" />
                ) : (
                  <Copy className="w-4 h-4" />
                )}
              </Button>
            </div>

            <div className="space-y-2 text-sm">
              <div className="flex justify-between">
                <span className="text-muted-foreground">Name</span>
                <span className="font-medium">{token.name}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-muted-foreground">Store</span>
                <span className="font-mono">{token.store_name}</span>
              </div>
              <div className="flex justify-between items-center">
                <span className="text-muted-foreground">Permissions</span>
                <div className="flex gap-1">
                  {token.permissions.read && (
                    <Badge variant="secondary">read</Badge>
                  )}
                  {token.permissions.write && (
                    <Badge variant="secondary">write</Badge>
                  )}
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
