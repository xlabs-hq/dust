import React, { useState } from "react";
import { Head, Link, router } from "@inertiajs/react";
import { Button } from "@/components/ui/Button";
import { Loader2 } from "lucide-react";

interface AuthorizeProps {
  client_id: string;
  client_name: string;
  redirect_uri: string;
  user_email: string;
  flow: string;
}

function Authorize({
  client_name,
  redirect_uri,
  user_email,
  flow,
}: AuthorizeProps) {
  const [pendingAction, setPendingAction] = useState<"allow" | "deny" | null>(
    null
  );
  const [error, setError] = useState<string | null>(null);

  function submit(action: "allow" | "deny") {
    setPendingAction(action);
    setError(null);
    router.post(
      "/oauth/authorize/approve",
      { flow, action },
      {
        onError: (errors) => {
          const values = Object.values(errors ?? {});
          const firstMessage = values.find(
            (value): value is string => typeof value === "string" && value.length > 0
          );
          setError(firstMessage ?? "Something went wrong. Please try again.");
        },
        onFinish: () => {
          setPendingAction(null);
        },
      }
    );
  }

  const loading = pendingAction !== null;

  return (
    <>
      <Head title="Authorize MCP client" />
      <div className="flex min-h-screen items-center justify-center bg-background">
        <div className="w-full max-w-sm space-y-8">
          <div className="text-center">
            <p className="text-4xl font-bold tracking-tight text-foreground">
              Dust
            </p>
            <h1 className="mt-2 text-sm text-muted-foreground">
              Authorize MCP client
            </h1>
          </div>

          <div className="space-y-6">
            <div className="text-center">
              <div className="text-xl font-semibold text-foreground">
                {client_name}
              </div>
              <p className="mt-2 text-sm text-muted-foreground">
                wants to access your Dust stores.
              </p>
            </div>

            <div className="space-y-3 border-t border-border pt-4 text-sm">
              <div className="text-muted-foreground">
                Signed in as{" "}
                <span className="text-foreground">{user_email}</span>{" "}
                <Link
                  href="/auth/login"
                  className="text-foreground underline-offset-4 hover:underline"
                >
                  (switch account)
                </Link>
              </div>

              <div className="text-xs text-muted-foreground">
                <div className="mb-1">Redirect URI</div>
                <div className="break-all rounded-md border border-border bg-muted px-2 py-1.5 font-mono text-foreground">
                  {redirect_uri}
                </div>
              </div>
            </div>

            {error && (
              <p className="text-sm text-destructive">{error}</p>
            )}

            <div className="flex gap-3">
              <Button
                type="button"
                variant="outline"
                className="flex-1"
                disabled={loading}
                onClick={() => submit("deny")}
                data-testid="oauth-deny"
                aria-label={`Deny ${client_name}`}
              >
                {pendingAction === "deny" && (
                  <Loader2 className="animate-spin" />
                )}
                Deny
              </Button>
              <Button
                type="button"
                className="flex-1"
                disabled={loading}
                onClick={() => submit("allow")}
                data-testid="oauth-allow"
                aria-label={`Allow ${client_name} to access your Dust stores`}
              >
                {pendingAction === "allow" && (
                  <Loader2 className="animate-spin" />
                )}
                Allow
              </Button>
            </div>
          </div>
        </div>
      </div>
    </>
  );
}

Authorize.layout = (page: React.ReactNode) => page;

export default Authorize;
