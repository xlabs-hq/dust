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
import { Plus, Key } from "lucide-react";

interface Token {
  id: string;
  name: string;
  store_name: string;
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
    if (!confirm("Are you sure you want to revoke this token? This cannot be undone.")) return;
    router.delete(`/${orgSlug}/tokens/${tokenId}`);
  }

  return (
    <>
      <Head title="Tokens" />
      <div className="space-y-6">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-2xl font-semibold tracking-tight text-foreground">
              Tokens
            </h1>
            <p className="text-sm text-muted-foreground mt-1">
              Manage API tokens for your stores
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
            <Key className="w-10 h-10 text-muted-foreground mb-4" />
            <h3 className="text-lg font-medium text-foreground">
              No tokens yet
            </h3>
            <p className="text-sm text-muted-foreground mt-1 mb-4">
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
                  <TableHead>Store</TableHead>
                  <TableHead>Permissions</TableHead>
                  <TableHead>Created</TableHead>
                  <TableHead>Last Used</TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {tokens.map((token) => (
                  <TableRow key={token.id}>
                    <TableCell className="font-medium">
                      {token.name}
                    </TableCell>
                    <TableCell className="font-mono text-sm text-muted-foreground">
                      {token.store_name}
                    </TableCell>
                    <TableCell>
                      <div className="flex gap-1">
                        {token.permissions.read && (
                          <Badge variant="secondary">read</Badge>
                        )}
                        {token.permissions.write && (
                          <Badge variant="secondary">write</Badge>
                        )}
                      </div>
                    </TableCell>
                    <TableCell className="text-muted-foreground">
                      {formatDate(token.inserted_at)}
                    </TableCell>
                    <TableCell className="text-muted-foreground">
                      {token.last_used_at
                        ? formatDate(token.last_used_at)
                        : "Never"}
                    </TableCell>
                    <TableActionsCell>
                      <Button
                        variant="ghost"
                        size="sm"
                        className="text-destructive hover:text-destructive"
                        onClick={() => handleRevoke(token.id)}
                      >
                        Revoke
                      </Button>
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
