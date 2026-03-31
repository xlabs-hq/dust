import React from "react";
import { Head, usePage } from "@inertiajs/react";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/Card";
import type { SharedProps } from "@/types";
import { Database, Key, Activity } from "lucide-react";

export default function Home() {
  const { current_user } = usePage<SharedProps>().props;

  const displayName = current_user?.name || current_user?.email || "there";

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

        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <Card>
            <CardHeader>
              <CardDescription className="flex items-center gap-2">
                <Database className="w-4 h-4" />
                Stores
              </CardDescription>
              <CardTitle className="text-3xl tabular-nums">--</CardTitle>
            </CardHeader>
            <CardContent>
              <p className="text-xs text-muted-foreground">
                Total data stores in this organization
              </p>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardDescription className="flex items-center gap-2">
                <Key className="w-4 h-4" />
                Tokens
              </CardDescription>
              <CardTitle className="text-3xl tabular-nums">--</CardTitle>
            </CardHeader>
            <CardContent>
              <p className="text-xs text-muted-foreground">
                Active API tokens
              </p>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardDescription className="flex items-center gap-2">
                <Activity className="w-4 h-4" />
                Connections
              </CardDescription>
              <CardTitle className="text-3xl tabular-nums">--</CardTitle>
            </CardHeader>
            <CardContent>
              <p className="text-xs text-muted-foreground">
                Active WebSocket connections
              </p>
            </CardContent>
          </Card>
        </div>
      </div>
    </>
  );
}
