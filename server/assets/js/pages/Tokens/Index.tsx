import React from "react";
import { Head, Link, router, usePage } from "@inertiajs/react";
import { Button } from "@/components/ui/Button";
import { Badge } from "@/components/ui/Badge";
import {
  Table,
  TableActionsCell,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/Table";
import type { SharedProps } from "@/types";
import { Key, Pencil, Plus } from "lucide-react";

interface TokenStore {
  id: string;
  name: string;
}

interface Token {
  id: string;
  name: string;
  store_label: string;
  store_access_mode: "all" | "selected";
  stores: TokenStore[];
  scopes: string[];
  permissions: { read: boolean; write: boolean };
  inserted_at: string;
  last_used_at: string | null;
}

interface TokensIndexProps extends SharedProps {
  tokens: Token[];
}

export default function TokensIndex() {
  const { tokens, current_organization } = usePage<TokensIndexProps>().props;
  const orgSlug = current_organization?.slug || "";

  function handleRevoke(tokenId: string) {
    if (!confirm("Are you sure you want to revoke this token? This cannot be undone.")) {
      return;
    }
    router.delete(`/${orgSlug}/tokens/${tokenId}`);
  }

  return (
    <>
      <Head title="Tokens" />
      <div className="space-y-6">
        <div className="flex items-center justify-between gap-4">
          <div>
            <h1 className="text-2xl font-semibold tracking-tight text-foreground">
              Tokens
            </h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Manage API tokens, store reach, and scopes
            </p>
          </div>
          <Button asChild>
            <Link href={`/${orgSlug}/tokens/new`}>
              <Plus className="w-4 h-4" />
              Create Token
            </Link>
          </Button>
        </div>

        {tokens.length === 0 ? (
          <div className="flex flex-col items-center justify-center rounded-lg border border-dashed p-12 text-center">
            <Key className="mb-4 h-10 w-10 text-muted-foreground" />
            <h3 className="text-lg font-medium text-foreground">No tokens yet</h3>
            <p className="mb-4 mt-1 text-sm text-muted-foreground">
              Create a token to authenticate API and SDK access to your stores.
            </p>
            <Button asChild>
              <Link href={`/${orgSlug}/tokens/new`}>
                <Plus className="w-4 h-4" />
                Create Token
              </Link>
            </Button>
          </div>
        ) : (
          <div className="rounded-lg border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Name</TableHead>
                  <TableHead>Store Access</TableHead>
                  <TableHead>Scopes</TableHead>
                  <TableHead>Created</TableHead>
                  <TableHead>Last Used</TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {tokens.map((token) => (
                  <TableRow key={token.id}>
                    <TableCell className="font-medium">{token.name}</TableCell>
                    <TableCell>
                      <div className="space-y-1">
                        <div className="font-mono text-sm text-muted-foreground">
                          {token.store_label}
                        </div>
                        <div className="flex gap-1">
                          {token.permissions.read && (
                            <Badge variant="secondary">read</Badge>
                          )}
                          {token.permissions.write && (
                            <Badge variant="secondary">write</Badge>
                          )}
                        </div>
                      </div>
                    </TableCell>
                    <TableCell>
                      <div className="flex max-w-md flex-wrap gap-1">
                        {token.scopes.slice(0, 6).map((scope) => (
                          <Badge key={scope} variant="outline">
                            {scope}
                          </Badge>
                        ))}
                        {token.scopes.length > 6 && (
                          <Badge variant="secondary">+{token.scopes.length - 6}</Badge>
                        )}
                      </div>
                    </TableCell>
                    <TableCell className="text-muted-foreground">
                      {formatDate(token.inserted_at)}
                    </TableCell>
                    <TableCell className="text-muted-foreground">
                      {token.last_used_at ? formatDate(token.last_used_at) : "Never"}
                    </TableCell>
                    <TableActionsCell>
                      <div className="flex justify-end gap-1">
                        <Button variant="ghost" size="sm" asChild>
                          <Link href={`/${orgSlug}/tokens/${token.id}/edit`}>
                            <Pencil className="h-4 w-4" />
                            Edit
                          </Link>
                        </Button>
                        <Button
                          variant="ghost"
                          size="sm"
                          className="text-destructive hover:text-destructive"
                          onClick={() => handleRevoke(token.id)}
                        >
                          Revoke
                        </Button>
                      </div>
                    </TableActionsCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </div>
    </>
  );
}

function formatDate(iso: string): string {
  return new Date(iso).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}
