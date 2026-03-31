import React, { useState } from "react";
import { Head, Link, router, usePage } from "@inertiajs/react";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { Label } from "@/components/ui/Label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/Select";
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
  ChevronLeft,
  ChevronRight,
  Filter,
  ScrollText,
} from "lucide-react";

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
}

interface Filters {
  path: string;
  device_id: string;
  op: string;
  since: string;
}

interface Pagination {
  page: number;
  limit: number;
  total: number;
  total_pages: number;
}

interface AuditLogProps extends SharedProps {
  store: Store;
  ops: Op[];
  filters: Filters;
  pagination: Pagination;
}

export default function AuditLog() {
  const { store, ops, filters, pagination, current_organization } =
    usePage<AuditLogProps>().props;
  const orgSlug = current_organization?.slug || "";

  const [path, setPath] = useState(filters.path);
  const [deviceId, setDeviceId] = useState(filters.device_id);
  const [op, setOp] = useState(filters.op);
  const [since, setSince] = useState(filters.since);

  function applyFilters(page = 1) {
    const params: Record<string, string | number> = { page };
    if (path) params.path = path;
    if (deviceId) params.device_id = deviceId;
    if (op) params.op = op;
    if (since) params.since = since;

    router.get(`/${orgSlug}/stores/${store.name}/log`, params, {
      preserveState: true,
      preserveScroll: true,
    });
  }

  function clearFilters() {
    setPath("");
    setDeviceId("");
    setOp("");
    setSince("");
    router.get(`/${orgSlug}/stores/${store.name}/log`, {}, {
      preserveState: false,
    });
  }

  function goToPage(page: number) {
    applyFilters(page);
  }

  const hasActiveFilters =
    filters.path || filters.device_id || filters.op || filters.since;

  return (
    <>
      <Head title={`Audit Log - ${store.name}`} />
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
              <ScrollText className="w-5 h-5 text-muted-foreground" />
              <h1 className="text-2xl font-semibold tracking-tight text-foreground">
                Audit Log
              </h1>
            </div>
            <p className="text-sm text-muted-foreground mt-1 font-mono">
              {store.full_name}
              <span className="ml-3 font-sans">
                {pagination.total}{" "}
                {pagination.total === 1 ? "operation" : "operations"}
              </span>
            </p>
          </div>
        </div>

        {/* Filter bar */}
        <div className="rounded-lg border p-4">
          <div className="flex items-center gap-2 mb-3 text-sm font-medium text-muted-foreground">
            <Filter className="w-4 h-4" />
            Filters
          </div>
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="filter-path" className="text-xs">
                Path
              </Label>
              <Input
                id="filter-path"
                placeholder="e.g. users.* or settings.theme"
                value={path}
                onChange={(e) => setPath(e.target.value)}
                onKeyDown={(e) => e.key === "Enter" && applyFilters()}
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="filter-device" className="text-xs">
                Device ID
              </Label>
              <Input
                id="filter-device"
                placeholder="Device ID"
                value={deviceId}
                onChange={(e) => setDeviceId(e.target.value)}
                onKeyDown={(e) => e.key === "Enter" && applyFilters()}
              />
            </div>
            <div className="space-y-1.5">
              <Label className="text-xs">Op Type</Label>
              <Select value={op} onValueChange={setOp}>
                <SelectTrigger className="w-full">
                  <SelectValue placeholder="All ops" />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="set">set</SelectItem>
                  <SelectItem value="delete">delete</SelectItem>
                  <SelectItem value="merge">merge</SelectItem>
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="filter-since" className="text-xs">
                Since
              </Label>
              <Input
                id="filter-since"
                type="datetime-local"
                value={since}
                onChange={(e) => setSince(e.target.value)}
                onKeyDown={(e) => e.key === "Enter" && applyFilters()}
              />
            </div>
          </div>
          <div className="flex gap-2 mt-3">
            <Button size="sm" onClick={() => applyFilters()}>
              Apply Filters
            </Button>
            {hasActiveFilters && (
              <Button size="sm" variant="ghost" onClick={clearFilters}>
                Clear
              </Button>
            )}
          </div>
        </div>

        {/* Op table */}
        {ops.length === 0 ? (
          <div className="flex flex-col items-center justify-center rounded-lg border border-dashed p-12 text-center">
            <ScrollText className="w-10 h-10 text-muted-foreground mb-4" />
            <h3 className="text-lg font-medium text-foreground">
              No operations found
            </h3>
            <p className="text-sm text-muted-foreground mt-1">
              {hasActiveFilters
                ? "Try adjusting your filters."
                : "Operations will appear here as clients write data."}
            </p>
          </div>
        ) : (
          <div className="rounded-lg border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="text-right w-[80px]">Seq</TableHead>
                  <TableHead className="w-[80px]">Op</TableHead>
                  <TableHead>Path</TableHead>
                  <TableHead className="max-w-xs">Value</TableHead>
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
                    <TableCell className="max-w-xs">
                      <span className="font-mono text-xs text-muted-foreground truncate block">
                        {truncateJson(op.value)}
                      </span>
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
        )}

        {/* Pagination */}
        {pagination.total_pages > 1 && (
          <div className="flex items-center justify-between text-sm">
            <p className="text-muted-foreground">
              Page {pagination.page} of {pagination.total_pages}
            </p>
            <div className="flex gap-2">
              <Button
                variant="outline"
                size="sm"
                disabled={pagination.page <= 1}
                onClick={() => goToPage(pagination.page - 1)}
              >
                <ChevronLeft className="w-4 h-4" />
                Previous
              </Button>
              <Button
                variant="outline"
                size="sm"
                disabled={pagination.page >= pagination.total_pages}
                onClick={() => goToPage(pagination.page + 1)}
              >
                Next
                <ChevronRight className="w-4 h-4" />
              </Button>
            </div>
          </div>
        )}
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
