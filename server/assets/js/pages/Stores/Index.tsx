import React from "react";
import { Head, Link, router, usePage } from "@inertiajs/react";
import { useChannel, useChannelEvent } from "@/lib/use-channel";
import { Button } from "@/components/ui/Button";
import { Badge } from "@/components/ui/Badge";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/Table";
import type { SharedProps } from "@/types";
import { Plus, Database } from "lucide-react";

interface Store {
  id: string;
  name: string;
  full_name: string;
  status: string;
  inserted_at: string;
  entry_count: number;
}

interface StoresIndexProps extends SharedProps {
  stores: Store[];
}

export default function StoresIndex() {
  const { stores, current_organization, socket_token } =
    usePage<StoresIndexProps>().props;
  const orgSlug = current_organization?.slug || "";

  const { channel } = useChannel({
    token: socket_token as string | null,
    topic: `ui:org:${orgSlug}`,
  });

  useChannelEvent(channel, "changed", () => {
    router.reload({ only: ["stores"] });
  });

  return (
    <>
      <Head title="Stores" />
      <div className="space-y-6">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-2xl font-semibold tracking-tight text-foreground">
              Stores
            </h1>
            <p className="text-sm text-muted-foreground mt-1">
              Manage your organization's data stores
            </p>
          </div>
          <Button asChild>
            <Link href={`/${orgSlug}/stores/new`}>
              <Plus className="w-4 h-4" />
              Create Store
            </Link>
          </Button>
        </div>

        {stores.length === 0 ? (
          <div className="flex flex-col items-center justify-center rounded-lg border border-dashed p-12 text-center">
            <Database className="w-10 h-10 text-muted-foreground mb-4" />
            <h3 className="text-lg font-medium text-foreground">No stores yet</h3>
            <p className="text-sm text-muted-foreground mt-1 mb-4">
              Create your first store to start syncing data.
            </p>
            <Button asChild>
              <Link href={`/${orgSlug}/stores/new`}>
                <Plus className="w-4 h-4" />
                Create Store
              </Link>
            </Button>
          </div>
        ) : (
          <div className="rounded-lg border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Name</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead className="text-right">Entries</TableHead>
                  <TableHead>Created</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {stores.map((store) => (
                  <TableRow
                    key={store.id}
                    className="cursor-pointer"
                    onClick={() =>
                      router.visit(`/${orgSlug}/stores/${store.name}`)
                    }
                  >
                    <TableCell className="font-mono text-sm font-medium">
                      {store.full_name}
                    </TableCell>
                    <TableCell>
                      <Badge
                        variant={
                          store.status === "active" ? "default" : "secondary"
                        }
                      >
                        {store.status}
                      </Badge>
                    </TableCell>
                    <TableCell className="text-right tabular-nums">
                      {store.entry_count}
                    </TableCell>
                    <TableCell className="text-muted-foreground">
                      {formatDate(store.inserted_at)}
                    </TableCell>
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
