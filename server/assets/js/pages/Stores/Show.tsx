import React from "react";
import { Head, Link, router, usePage } from "@inertiajs/react";
import { toast } from "sonner";
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
import GettingStartedSnippets from "@/components/GettingStartedSnippets";
import { EntryEditor } from "@/components/EntryEditor";
import type { SharedProps } from "@/types";
import {
  ArrowLeft,
  FileText,
  Pencil,
  Plus,
  ScrollText,
  Trash2,
  Webhook,
} from "lucide-react";

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
  const entriesEndpoint = `/api/stores/${orgSlug}/${store.name}/entries`;

  const { channel } = useChannel({
    token: socket_token as string | null,
    topic: `ui:store:${store.full_name}`,
  });

  useChannelEvent(channel, "changed", () => {
    router.reload({ only: ["store", "entries", "ops", "current_seq"] });
  });

  // Editor state — a single modal handles both create and edit. When
  // editingPath is null we're in "create" mode; otherwise we're editing
  // the entry whose path matches.
  const [editorOpen, setEditorOpen] = React.useState(false);
  const [editingEntry, setEditingEntry] = React.useState<Entry | null>(null);

  function openCreate() {
    setEditingEntry(null);
    setEditorOpen(true);
  }

  function openEdit(entry: Entry) {
    setEditingEntry(entry);
    setEditorOpen(true);
  }

  function refreshAfterWrite() {
    // The channel-driven `changed` event will also fire, but reloading
    // here closes the optimistic gap: the user sees their change land
    // immediately, not "soon after the WebSocket round-trips."
    router.reload({ only: ["store", "entries", "ops", "current_seq"] });
  }

  async function handleDelete(entry: Entry) {
    if (!window.confirm(`Delete ${entry.path}?`)) return;

    try {
      const res = await fetch(entriesEndpoint, {
        method: "DELETE",
        credentials: "same-origin",
        headers: {
          "content-type": "application/json",
          accept: "application/json",
          ...(getCsrfHeader() || {}),
        },
        body: JSON.stringify({ path: entry.path }),
      });

      if (!res.ok) {
        const body = await res.json().catch(() => ({}));
        toast.error(body.error || body.detail || `Delete failed (HTTP ${res.status})`);
        return;
      }

      toast.success(`Deleted ${entry.path}`);
      refreshAfterWrite();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Network error — please retry");
    }
  }

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

          <TabsContent value="data" className="space-y-3">
            <div className="flex justify-end">
              <Button size="sm" onClick={openCreate}>
                <Plus className="w-4 h-4" />
                New entry
              </Button>
            </div>

            {entries.length === 0 ? (
              <GettingStartedSnippets
                storeFullName={store.full_name}
                orgSlug={orgSlug}
              />
            ) : (
              <div className="rounded-lg border">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Path</TableHead>
                      <TableHead>Value</TableHead>
                      <TableHead>Type</TableHead>
                      <TableHead className="text-right">Seq</TableHead>
                      <TableHead className="w-[1%] text-right">Actions</TableHead>
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
                        <TableCell className="text-right whitespace-nowrap">
                          <Button
                            variant="ghost"
                            size="icon"
                            aria-label={`Edit ${entry.path}`}
                            onClick={() => openEdit(entry)}
                          >
                            <Pencil className="w-4 h-4" />
                          </Button>
                          <Button
                            variant="ghost"
                            size="icon"
                            aria-label={`Delete ${entry.path}`}
                            onClick={() => handleDelete(entry)}
                          >
                            <Trash2 className="w-4 h-4 text-destructive" />
                          </Button>
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

        <EntryEditor
          mode={editingEntry ? "edit" : "create"}
          open={editorOpen}
          onOpenChange={setEditorOpen}
          endpoint={entriesEndpoint}
          path={editingEntry?.path}
          initialValue={editingEntry?.value}
          onSaved={refreshAfterWrite}
        />
      </div>
    </>
  );
}

function getCsrfHeader(): Record<string, string> | null {
  if (typeof document === "undefined") return null;
  const meta = document.querySelector('meta[name="csrf-token"]');
  const token = meta?.getAttribute("content");
  return token ? { "x-csrf-token": token } : null;
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
