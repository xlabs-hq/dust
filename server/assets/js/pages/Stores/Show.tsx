import React from "react";
import { Head, Link, router, usePage } from "@inertiajs/react";
import { useChannel, useChannelEvent } from "@/lib/use-channel";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/Table";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/Tabs";
import type { SharedProps } from "@/types";
import { ArrowLeft, Database, FileText, ScrollText, Webhook } from "lucide-react";

interface Entry {
  path: string;
  value: unknown;
  type: string;
  seq: number;
}

interface Op {
  store_seq: number;
  op: string;
  path: string;
  value: unknown;
  device_id: string;
  inserted_at: string;
}

interface Store {
  id: string;
  name: string;
  full_name: string;
  status: string;
  inserted_at: string;
  expires_at: string | null;
  entry_count: number;
}

interface StoreShowProps extends SharedProps {
  store: Store;
  entries: Entry[];
  ops: Op[];
  current_seq: number;
}

export default function StoreShow() {
  const { store, entries, ops, current_seq, current_organization, socket_token } =
    usePage<StoreShowProps>().props;
  const orgSlug = current_organization?.slug || "";

  const { channel } = useChannel({
    token: socket_token as string | null,
    topic: `ui:store:${store.full_name}`,
  });

  useChannelEvent(channel, "changed", () => {
    router.reload({ only: ["store", "entries", "ops", "current_seq"] });
  });

  return (
    <>
      <Head title={store.full_name} />
      <div className="space-y-6">
        {/* Header */}
        <div className="flex items-start gap-4">
          <Button variant="ghost" size="icon" asChild>
            <Link href={`/${orgSlug}/stores`}>
              <ArrowLeft className="w-4 h-4" />
            </Link>
          </Button>
          <div className="flex-1">
            <div className="flex items-center gap-3">
              <h1 className="text-2xl font-semibold tracking-tight text-foreground font-mono">
                {store.full_name}
              </h1>
              <Badge
                variant={store.status === "active" ? "default" : "secondary"}
              >
                {store.status}
              </Badge>
              {store.expires_at && (
                <Badge variant="outline">
                  Expires {new Date(store.expires_at).toLocaleString()}
                </Badge>
              )}
            </div>
            <p className="text-sm text-muted-foreground mt-1">
              Seq {current_seq} · {store.entry_count}{" "}
              {store.entry_count === 1 ? "entry" : "entries"}
            </p>
          </div>
          <div className="flex gap-2">
            <Button variant="outline" size="sm" asChild>
              <Link href={`/${orgSlug}/stores/${store.name}/webhooks`}>
                <Webhook className="w-4 h-4" />
                Webhooks
              </Link>
            </Button>
          </div>
        </div>

        {/* Tabs */}
        <Tabs defaultValue="data">
          <TabsList>
            <TabsTrigger value="data" className="gap-1.5">
              <FileText className="w-4 h-4" />
              Data
            </TabsTrigger>
            <TabsTrigger value="ops" className="gap-1.5">
              <ScrollText className="w-4 h-4" />
              Op Log
            </TabsTrigger>
          </TabsList>

          <TabsContent value="data">
            {entries.length === 0 ? (
              <div className="flex flex-col items-center justify-center rounded-lg border border-dashed p-12 text-center">
                <Database className="w-10 h-10 text-muted-foreground mb-4" />
                <h3 className="text-lg font-medium text-foreground">
                  No entries yet
                </h3>
                <p className="text-sm text-muted-foreground mt-1">
                  Connect a client to start writing data to this store.
                </p>
              </div>
            ) : (
              <div className="rounded-lg border">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Path</TableHead>
                      <TableHead>Value</TableHead>
                      <TableHead>Type</TableHead>
                      <TableHead className="text-right">Seq</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {entries.map((entry) => (
                      <TableRow key={entry.path}>
                        <TableCell className="font-mono text-sm">
                          {entry.path}
                        </TableCell>
                        <TableCell className="max-w-xs">
                          <span className="font-mono text-xs text-muted-foreground truncate block">
                            {truncateJson(entry.value)}
                          </span>
                        </TableCell>
                        <TableCell>
                          <Badge variant="outline">{entry.type}</Badge>
                        </TableCell>
                        <TableCell className="text-right tabular-nums">
                          {entry.seq}
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>
            )}
          </TabsContent>

          <TabsContent value="ops">
            {ops.length === 0 ? (
              <div className="flex flex-col items-center justify-center rounded-lg border border-dashed p-12 text-center">
                <ScrollText className="w-10 h-10 text-muted-foreground mb-4" />
                <h3 className="text-lg font-medium text-foreground">
                  No operations yet
                </h3>
                <p className="text-sm text-muted-foreground mt-1">
                  Operations will appear here as clients write data.
                </p>
              </div>
            ) : (
              <>
                <div className="rounded-lg border">
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead className="text-right">Seq</TableHead>
                        <TableHead>Op</TableHead>
                        <TableHead>Path</TableHead>
                        <TableHead>Device</TableHead>
                        <TableHead>Time</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {ops.map((op) => (
                        <TableRow key={op.store_seq}>
                          <TableCell className="text-right tabular-nums">
                            {op.store_seq}
                          </TableCell>
                          <TableCell>
                            <OpBadge op={op.op} />
                          </TableCell>
                          <TableCell className="font-mono text-sm">
                            {op.path}
                          </TableCell>
                          <TableCell className="font-mono text-xs text-muted-foreground">
                            {op.device_id
                              ? op.device_id.slice(0, 8) + "..."
                              : "--"}
                          </TableCell>
                          <TableCell className="text-muted-foreground">
                            {formatDateTime(op.inserted_at)}
                          </TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </div>
                <div className="mt-3">
                  <Button variant="outline" size="sm" asChild>
                    <Link href={`/${orgSlug}/stores/${store.name}/log`}>
                      View full audit log
                    </Link>
                  </Button>
                </div>
              </>
            )}
          </TabsContent>
        </Tabs>
      </div>
    </>
  );
}

function OpBadge({ op }: { op: string }) {
  const variant =
    op === "delete" ? "destructive" : op === "merge" ? "secondary" : "default";
  return <Badge variant={variant}>{op}</Badge>;
}

function truncateJson(value: unknown): string {
  const str = JSON.stringify(value);
  if (str.length > 80) return str.slice(0, 80) + "...";
  return str;
}

function formatDateTime(iso: string): string {
  return new Date(iso).toLocaleString("en-US", {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}
