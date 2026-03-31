import React from "react";

interface ShellProps {
  children: React.ReactNode;
}

/**
 * Shell layout — persistent layout wrapper for all Inertia pages.
 * Will be expanded with navigation, sidebar, etc. in later tasks.
 */
export function Shell({ children }: ShellProps) {
  return <div className="min-h-screen bg-background">{children}</div>;
}
