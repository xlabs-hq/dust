import React, { useState } from "react";
import { Head, Link, useForm, usePage, router } from "@inertiajs/react";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/Table";
import type { SharedProps } from "@/types";
import {
  ArrowLeft,
  Plus,
  Trash2,
  ChevronDown,
  ChevronRight,
  Webhook,
  ExternalLink,
  AlertCircle,
} from "lucide-react";

interface Delivery {
  store_seq: number;
  status_code: number | null;
  response_ms: number | null;
  error: string | null;
  attempted_at: string;
}

interface WebhookEntry {
  id: string;
  url: string;
  active: boolean;
  last_delivered_seq: number;
  failure_count: number;
  created_at: string;
  deliveries: Delivery[];
}

interface Store {
  id: string;
  name: string;
  full_name: string;
}

interface WebhooksProps extends SharedProps {
  store: Store;
  webhooks: WebhookEntry[];
}

export default function Webhooks() {
  const { store, webhooks, current_organization } =
    usePage<WebhooksProps>().props;
  const orgSlug = current_organization?.slug || "";

  const form = useForm({ url: "" });

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    form.post(`/${orgSlug}/stores/${store.name}/webhooks`, {
      onSuccess: () => form.reset(),
    });
  }

  function handleDelete(webhookId: string) {
    if (!window.confirm("Delete this webhook? This cannot be undone.")) return;
    router.delete(`/${orgSlug}/stores/${store.name}/webhooks/${webhookId}`);
  }

  return (
    <>
      <Head title={`Webhooks - ${store.name}`} />
      <div className="space-y-6">
        {/* Header */}
        <div className="flex items-start gap-4">
          <Button variant="ghost" size="icon" asChild>
            <Link href={`/${orgSlug}/stores/${store.name}`}>
              <ArrowLeft className="w-4 h-4" />
            </Link>
          </Button>
          <div className="flex-1">
            <div className="flex items-center gap-3">
              <Webhook className="w-5 h-5 text-muted-foreground" />
              <h1 className="text-2xl font-semibold tracking-tight text-foreground">
                Webhooks
              </h1>
            </div>
            <p className="text-sm text-muted-foreground mt-1 font-mono">
              {store.full_name}
              <span className="ml-3 font-sans">
                {webhooks.length}{" "}
                {webhooks.length === 1 ? "webhook" : "webhooks"}
              </span>
            </p>
          </div>
        </div>

        {/* Create form */}
        <form onSubmit={handleSubmit} className="rounded-lg border p-4">
          <div className="flex items-end gap-3">
            <div className="flex-1 space-y-1.5">
              <label
                htmlFor="webhook-url"
                className="text-sm font-medium text-foreground"
              >
                Endpoint URL
              </label>
              <Input
                id="webhook-url"
                type="url"
                placeholder="https://example.com/webhooks/dust"
                value={form.data.url}
                onChange={(e) => form.setData("url", e.target.value)}
                disabled={form.processing}
              />
            </div>
            <Button type="submit" disabled={form.processing || !form.data.url}>
              <Plus className="w-4 h-4" />
              Add webhook
            </Button>
          </div>
          <p className="text-xs text-muted-foreground mt-2">
            A signing secret will be generated and shown once after creation.
          </p>
        </form>

        {/* Webhook list */}
        {webhooks.length === 0 ? (
          <div className="flex flex-col items-center justify-center rounded-lg border border-dashed p-12 text-center">
            <Webhook className="w-10 h-10 text-muted-foreground mb-4" />
            <h3 className="text-lg font-medium text-foreground">
              No webhooks yet
            </h3>
            <p className="text-sm text-muted-foreground mt-1">
              Add an endpoint URL above to receive real-time notifications when
              data changes.
            </p>
          </div>
        ) : (
          <div className="space-y-3">
            {webhooks.map((wh) => (
              <WebhookCard
                key={wh.id}
                webhook={wh}
                onDelete={() => handleDelete(wh.id)}
              />
            ))}
          </div>
        )}
      </div>
    </>
  );
}

function WebhookCard({
  webhook,
  onDelete,
}: {
  webhook: WebhookEntry;
  onDelete: () => void;
}) {
  const [expanded, setExpanded] = useState(false);

  return (
    <div className="rounded-lg border">
      <div className="p-4">
        <div className="flex items-start justify-between gap-4">
          <div className="flex-1 min-w-0">
            <div className="flex items-center gap-2.5">
              <Badge variant={webhook.active ? "default" : "destructive"}>
                {webhook.active ? "Active" : "Inactive"}
              </Badge>
              <span className="font-mono text-sm truncate" title={webhook.url}>
                {webhook.url}
              </span>
              <a
                href={webhook.url}
                target="_blank"
                rel="noopener noreferrer"
                className="text-muted-foreground hover:text-foreground shrink-0"
              >
                <ExternalLink className="w-3.5 h-3.5" />
              </a>
            </div>
            <div className="flex items-center gap-4 mt-2 text-xs text-muted-foreground">
              <span>
                Last delivered seq:{" "}
                <span className="tabular-nums font-mono">
                  {webhook.last_delivered_seq}
                </span>
              </span>
              {webhook.failure_count > 0 && (
                <span className="flex items-center gap-1 text-destructive">
                  <AlertCircle className="w-3 h-3" />
                  {webhook.failure_count}{" "}
                  {webhook.failure_count === 1 ? "failure" : "failures"}
                </span>
              )}
              <span>Created {formatDate(webhook.created_at)}</span>
            </div>
          </div>
          <div className="flex items-center gap-1 shrink-0">
            <Button
              variant="ghost"
              size="icon-sm"
              onClick={() => setExpanded(!expanded)}
              title={expanded ? "Hide deliveries" : "Show deliveries"}
            >
              {expanded ? (
                <ChevronDown className="w-4 h-4" />
              ) : (
                <ChevronRight className="w-4 h-4" />
              )}
            </Button>
            <Button
              variant="ghost"
              size="icon-sm"
              onClick={onDelete}
              className="text-muted-foreground hover:text-destructive"
              title="Delete webhook"
            >
              <Trash2 className="w-4 h-4" />
            </Button>
          </div>
        </div>
      </div>

      {/* Delivery log */}
      {expanded && (
        <div className="border-t">
          {webhook.deliveries.length === 0 ? (
            <div className="px-4 py-6 text-center text-sm text-muted-foreground">
              No deliveries recorded yet.
            </div>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="text-right w-[80px]">Seq</TableHead>
                  <TableHead className="w-[100px]">Status</TableHead>
                  <TableHead className="w-[100px] text-right">
                    Latency
                  </TableHead>
                  <TableHead>Error</TableHead>
                  <TableHead>Time</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {webhook.deliveries.map((d, i) => (
                  <TableRow key={i}>
                    <TableCell className="text-right tabular-nums font-mono text-sm">
                      {d.store_seq}
                    </TableCell>
                    <TableCell>
                      <StatusBadge code={d.status_code} error={d.error} />
                    </TableCell>
                    <TableCell className="text-right tabular-nums text-sm text-muted-foreground">
                      {d.response_ms != null ? `${d.response_ms}ms` : "--"}
                    </TableCell>
                    <TableCell className="text-sm text-muted-foreground max-w-xs truncate">
                      {d.error || "--"}
                    </TableCell>
                    <TableCell className="text-sm text-muted-foreground">
                      {formatDateTime(d.attempted_at)}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </div>
      )}
    </div>
  );
}

function StatusBadge({
  code,
  error,
}: {
  code: number | null;
  error: string | null;
}) {
  if (error) {
    return <Badge variant="destructive">Error</Badge>;
  }
  if (code == null) {
    return <Badge variant="secondary">--</Badge>;
  }
  if (code >= 200 && code < 300) {
    return <Badge variant="default">{code}</Badge>;
  }
  return <Badge variant="destructive">{code}</Badge>;
}

function formatDate(iso: string): string {
  return new Date(iso).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

function formatDateTime(iso: string): string {
  return new Date(iso).toLocaleString("en-US", {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}
