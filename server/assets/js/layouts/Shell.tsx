import React, { useState, useEffect } from "react";
import { Link, usePage } from "@inertiajs/react";
import { toast } from "sonner";
import { UserMenu } from "@/components/UserMenu";
import { OrganizationSwitcher } from "@/components/OrganizationSwitcher";
import { Toaster } from "@/components/ui/Toaster";
import type { SharedProps } from "@/types";
import { Database, Key, Settings, Menu, X } from "lucide-react";

interface ShellProps {
  children: React.ReactNode;
}

interface NavItem {
  name: string;
  href: string;
  icon: React.ReactNode;
}

export function Shell({ children }: ShellProps) {
  const { current_user, current_organization, user_organizations, flash } =
    usePage<SharedProps>().props;
  const orgSlug = current_organization?.slug || "";
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false);

  // Determine active path for highlighting
  const url = usePage().url;

  const navItems: NavItem[] = [
    {
      name: "Stores",
      href: `/${orgSlug}/stores`,
      icon: <Database className="w-5 h-5" />,
    },
    {
      name: "Tokens",
      href: `/${orgSlug}/tokens`,
      icon: <Key className="w-5 h-5" />,
    },
    {
      name: "Settings",
      href: `/${orgSlug}/settings`,
      icon: <Settings className="w-5 h-5" />,
    },
  ];

  // Fire toast notifications from flash messages
  useEffect(() => {
    if (flash.info) toast.success(flash.info);
    if (flash.error) toast.error(flash.error);
  }, [flash.info, flash.error]);

  const isActive = (href: string) => {
    // Exact match for root, starts-with for others
    return url === href || url.startsWith(href + "/");
  };

  const renderNavigation = (onLinkClick?: () => void) => (
    <nav className="flex-1 px-4 py-4 overflow-y-auto">
      <div className="space-y-1">
        {navItems.map((item) => (
          <Link
            key={item.name}
            href={item.href}
            onClick={onLinkClick}
            className={`flex items-center gap-3 px-3 py-2 text-sm font-medium rounded-lg transition-colors ${
              isActive(item.href)
                ? "bg-accent text-accent-foreground"
                : "text-muted-foreground hover:text-foreground hover:bg-accent/50"
            }`}
          >
            {item.icon}
            {item.name}
          </Link>
        ))}
      </div>
    </nav>
  );

  return (
    <div className="min-h-screen bg-background">
      <Toaster />

      {/* Mobile menu overlay */}
      {mobileMenuOpen && (
        <div
          className="fixed inset-0 z-50 bg-background/80 backdrop-blur-sm lg:hidden"
          onClick={() => setMobileMenuOpen(false)}
        />
      )}

      {/* Mobile menu drawer */}
      <aside
        className={`fixed inset-y-0 left-0 z-50 w-64 bg-muted/50 border-r border-border flex flex-col transform transition-transform duration-200 ease-in-out lg:hidden ${
          mobileMenuOpen ? "translate-x-0" : "-translate-x-full"
        }`}
      >
        <div className="flex items-center justify-between h-14 px-6 border-b border-border">
          <Link href={`/${orgSlug}`} className="flex items-center gap-2">
            <span className="font-semibold text-foreground">Dust</span>
          </Link>
          <button
            onClick={() => setMobileMenuOpen(false)}
            className="p-2 rounded-md text-muted-foreground hover:text-foreground hover:bg-accent transition-colors"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        {current_organization && (
          <OrganizationSwitcher
            currentOrganization={current_organization}
            organizations={user_organizations || []}
          />
        )}

        {renderNavigation(() => setMobileMenuOpen(false))}
      </aside>

      {/* Desktop sidebar */}
      <aside className="fixed inset-y-0 left-0 z-50 w-64 bg-muted/50 border-r border-border hidden lg:flex lg:flex-col">
        <div className="flex items-center h-14 px-6 border-b border-border">
          <Link href={`/${orgSlug}`} className="flex items-center gap-2">
            <span className="font-semibold text-foreground">Dust</span>
          </Link>
        </div>

        {current_organization && (
          <OrganizationSwitcher
            currentOrganization={current_organization}
            organizations={user_organizations || []}
          />
        )}

        {renderNavigation()}
      </aside>

      {/* Main content area */}
      <div className="lg:pl-64">
        {/* Top bar */}
        <header className="sticky top-0 z-40 h-14 bg-background border-b border-border flex items-center justify-between px-6">
          <button
            onClick={() => setMobileMenuOpen(true)}
            className="lg:hidden p-2 rounded-md text-muted-foreground hover:text-foreground hover:bg-accent transition-colors"
          >
            <Menu className="w-5 h-5" />
          </button>

          <div className="flex-1" />

          <div className="flex items-center gap-2">
            {current_user && (
              <UserMenu
                email={current_user.email}
                name={current_user.name}
              />
            )}
          </div>
        </header>

        {/* Page content */}
        <main className="p-6">{children}</main>
      </div>
    </div>
  );
}
