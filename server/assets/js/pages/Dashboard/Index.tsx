import React from "react";
import { Head, Link, usePage } from "@inertiajs/react";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import type { SharedProps } from "@/types";
import { Database, Key, FileText, Plus } from "lucide-react";

interface DashboardProps extends SharedProps {
  stats: {
    stores: number;
    tokens: number;
    entries: number;
  };
}

export default function DashboardIndex() {
  const { current_user, current_organization, stats } =
    usePage<DashboardProps>().props;

  const orgSlug = current_organization?.slug || "";
  const displayName = current_user?.name || current_user?.email || "there";
  const isEmpty = stats.stores === 0;

  return (
    <>
      <Head title="Dashboard" />
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight text-foreground">
            Dashboard
          </h1>
          <p className="text-sm text-muted-foreground mt-1">
            Welcome back, {displayName}
          </p>
        </div>

        {isEmpty && (
          <Card className="border-dashed">
            <CardHeader>
              <CardTitle className="text-xl">
                Create your first store
              </CardTitle>
              <CardDescription>
                A store is a named, reactive map of keys and values. Every
                connected client subscribes to it and reacts to changes in
                real time.
              </CardDescription>
            </CardHeader>
            <CardContent>
              <Link href={`/${orgSlug}/stores/new`}>
                <Button size="lg" className="gap-2">
                  <Plus className="w-4 h-4" />
                  New store
                </Button>
              </Link>
            </CardContent>
          </Card>
        )}

        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <Link href={`/${orgSlug}/stores`} className="block">
            <Card className="transition-colors hover:border-foreground/20">
              <CardHeader>
                <CardDescription className="flex items-center gap-2">
                  <Database className="w-4 h-4" />
                  Stores
                </CardDescription>
                <CardTitle className="text-3xl tabular-nums">
                  {stats.stores}
                </CardTitle>
              </CardHeader>
              <CardContent>
                <p className="text-xs text-muted-foreground">
                  Total data stores in this organization
                </p>
              </CardContent>
            </Card>
          </Link>

          <Link href={`/${orgSlug}/tokens`} className="block">
            <Card className="transition-colors hover:border-foreground/20">
              <CardHeader>
                <CardDescription className="flex items-center gap-2">
                  <Key className="w-4 h-4" />
                  Tokens
                </CardDescription>
                <CardTitle className="text-3xl tabular-nums">
                  {stats.tokens}
                </CardTitle>
              </CardHeader>
              <CardContent>
                <p className="text-xs text-muted-foreground">
                  Active API tokens
                </p>
              </CardContent>
            </Card>
          </Link>

          <Card>
            <CardHeader>
              <CardDescription className="flex items-center gap-2">
                <FileText className="w-4 h-4" />
                Entries
              </CardDescription>
              <CardTitle className="text-3xl tabular-nums">
                {stats.entries}
              </CardTitle>
            </CardHeader>
            <CardContent>
              <p className="text-xs text-muted-foreground">
                Total entries across all stores
              </p>
            </CardContent>
          </Card>
        </div>
      </div>
    </>
  );
}
