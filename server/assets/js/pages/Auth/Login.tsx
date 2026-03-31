import React from "react";
import { Head } from "@inertiajs/react";

function Login() {
  return (
    <>
      <Head title="Sign in" />
      <div className="flex min-h-screen items-center justify-center bg-background">
        <div className="w-full max-w-sm space-y-8 text-center">
          <div>
            <h1 className="text-4xl font-bold tracking-tight text-foreground">
              Dust
            </h1>
            <p className="mt-2 text-sm text-muted-foreground">
              Reactive state management for AI agents
            </p>
          </div>

          <a
            href="/auth/authorize"
            className="inline-flex h-10 w-full items-center justify-center rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground shadow-sm transition-colors hover:bg-primary/90 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
          >
            Sign in
          </a>

          <p className="text-xs text-muted-foreground">
            Sign in with your WorkOS account to get started.
          </p>
        </div>
      </div>
    </>
  );
}

// Opt out of the Shell layout — Login uses its own full-screen layout
Login.layout = (page: React.ReactNode) => page;

export default Login;
