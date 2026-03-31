import React from "react";
import { Head } from "@inertiajs/react";

export default function Home() {
  return (
    <>
      <Head title="Home" />
      <div className="flex min-h-screen items-center justify-center">
        <div className="text-center">
          <h1 className="text-4xl font-bold tracking-tight text-foreground">
            Dust
          </h1>
          <p className="mt-2 text-muted-foreground">
            Reactive state management for AI agents
          </p>
        </div>
      </div>
    </>
  );
}
