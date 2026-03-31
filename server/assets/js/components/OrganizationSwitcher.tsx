import { router } from "@inertiajs/react";
import { ChevronsUpDown, Check } from "lucide-react";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/DropdownMenu";
import type { Organization } from "@/types";

interface OrganizationSwitcherProps {
  currentOrganization: Organization;
  organizations: Organization[];
}

export function OrganizationSwitcher({
  currentOrganization,
  organizations,
}: OrganizationSwitcherProps) {
  const hasMultipleOrgs = organizations.length > 1;

  const handleSwitch = (org: Organization) => {
    if (org.id !== currentOrganization.id) {
      router.visit(`/${org.slug}/stores`);
    }
  };

  if (!hasMultipleOrgs) {
    return (
      <div className="px-4 py-3 border-b border-border">
        <div className="text-xs text-muted-foreground uppercase tracking-wider mb-1">
          Organization
        </div>
        <div className="font-medium text-sm truncate text-foreground">
          {currentOrganization.name}
        </div>
      </div>
    );
  }

  return (
    <div className="px-4 py-3 border-b border-border">
      <div className="text-xs text-muted-foreground uppercase tracking-wider mb-1">
        Organization
      </div>
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <button className="w-full flex items-center justify-between gap-2 px-2 py-1.5 -mx-2 rounded-md hover:bg-accent transition-colors text-left">
            <span className="font-medium text-sm truncate text-foreground">
              {currentOrganization.name}
            </span>
            <ChevronsUpDown className="w-4 h-4 text-muted-foreground shrink-0" />
          </button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="start" className="w-56">
          {organizations.map((org) => (
            <DropdownMenuItem
              key={org.id}
              onClick={() => handleSwitch(org)}
              className="flex items-center justify-between"
            >
              <span className="truncate">{org.name}</span>
              {org.id === currentOrganization.id && (
                <Check className="w-4 h-4 text-primary shrink-0" />
              )}
            </DropdownMenuItem>
          ))}
        </DropdownMenuContent>
      </DropdownMenu>
    </div>
  );
}
