import React, { useMemo, useState } from "react";
import { Head, Link, router, usePage } from "@inertiajs/react";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { Label } from "@/components/ui/Label";
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from "@/components/ui/Card";
import type { SharedProps } from "@/types";
import { ArrowLeft, Check } from "lucide-react";

interface StoreOption {
  id: string;
  name: string;
}

interface ScopeDefinition {
  scope: string;
  label: string;
  description: string;
  group: string;
}

interface EditableToken {
  id: string;
  name: string;
  store_access_mode: "all" | "selected";
  store_ids: string[];
  scopes: string[];
}

interface EditTokenProps extends SharedProps {
  token: EditableToken;
  stores: StoreOption[];
  scope_definitions: ScopeDefinition[];
  errors?: Record<string, string[]>;
}

export default function TokensEdit() {
  const { current_organization, token, stores, scope_definitions, errors } =
    usePage<EditTokenProps>().props;
  const orgSlug = current_organization?.slug || "";

  const [name, setName] = useState(token.name);
  const [storeAccessMode, setStoreAccessMode] = useState<"all" | "selected">(
    token.store_access_mode
  );
  const [storeIds, setStoreIds] = useState<string[]>(token.store_ids || []);
  const [scopes, setScopes] = useState<string[]>(token.scopes || []);
  const [submitting, setSubmitting] = useState(false);

  const groupedScopes = useMemo(() => groupScopes(scope_definitions), [scope_definitions]);
  const isValid =
    name.trim().length > 0 &&
    scopes.length > 0 &&
    (storeAccessMode === "all" || storeIds.length > 0);

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!isValid) return;
    setSubmitting(true);
    router.put(
      `/${orgSlug}/tokens/${token.id}`,
      {
        name,
        store_access_mode: storeAccessMode,
        store_ids: storeAccessMode === "selected" ? storeIds : [],
        scopes,
      },
      { onFinish: () => setSubmitting(false) }
    );
  }

  return (
    <>
      <Head title="Edit Token" />
      <div className="max-w-3xl space-y-6">
        <div className="flex items-center gap-4">
          <Button variant="ghost" size="icon" asChild>
            <Link href={`/${orgSlug}/tokens`}>
              <ArrowLeft className="w-4 h-4" />
            </Link>
          </Button>
          <div>
            <h1 className="text-2xl font-semibold tracking-tight text-foreground">
              Edit Token
            </h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Update account reach and action scopes.
            </p>
          </div>
        </div>

        <Card>
          <form onSubmit={handleSubmit}>
            <CardHeader>
              <CardTitle>Token Details</CardTitle>
              <CardDescription>Changes apply to future API requests.</CardDescription>
            </CardHeader>
            <CardContent className="space-y-6">
              <div className="space-y-2">
                <Label htmlFor="name">Token Name</Label>
                <Input
                  id="name"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  aria-invalid={errors?.name ? true : undefined}
                />
                {errors?.name && (
                  <p className="text-sm text-destructive">{errors.name[0]}</p>
                )}
              </div>

              <section className="space-y-3">
                <Label>Store Access</Label>
                <div className="grid gap-2 sm:grid-cols-2">
                  <AccessModeButton
                    active={storeAccessMode === "selected"}
                    title="Selected stores"
                    onClick={() => setStoreAccessMode("selected")}
                  />
                  <AccessModeButton
                    active={storeAccessMode === "all"}
                    title="All current and future stores"
                    onClick={() => setStoreAccessMode("all")}
                  />
                </div>

                {storeAccessMode === "selected" && (
                  <div className="grid gap-2 rounded-md border p-3 sm:grid-cols-2">
                    {stores.map((store) => (
                      <CheckboxRow
                        key={store.id}
                        checked={storeIds.includes(store.id)}
                        label={store.name}
                        onChange={(checked) =>
                          setStoreIds(toggleValue(storeIds, store.id, checked))
                        }
                      />
                    ))}
                  </div>
                )}
                {errors?.store_ids && (
                  <p className="text-sm text-destructive">{errors.store_ids[0]}</p>
                )}
              </section>

              <section className="space-y-3">
                <Label>Scopes</Label>
                <div className="grid gap-4 md:grid-cols-2">
                  {groupedScopes.map(([group, definitions]) => (
                    <div key={group} className="space-y-2 rounded-md border p-3">
                      <div className="text-sm font-medium">{group}</div>
                      {definitions.map((definition) => (
                        <CheckboxRow
                          key={definition.scope}
                          checked={scopes.includes(definition.scope)}
                          label={definition.label}
                          detail={definition.scope}
                          onChange={(checked) =>
                            setScopes(toggleValue(scopes, definition.scope, checked))
                          }
                        />
                      ))}
                    </div>
                  ))}
                </div>
                {errors?.scopes && (
                  <p className="text-sm text-destructive">{errors.scopes[0]}</p>
                )}
              </section>
            </CardContent>
            <CardFooter className="justify-end gap-2">
              <Button variant="outline" asChild>
                <Link href={`/${orgSlug}/tokens`}>Cancel</Link>
              </Button>
              <Button type="submit" disabled={!isValid || submitting}>
                {submitting ? "Saving..." : "Save Changes"}
              </Button>
            </CardFooter>
          </form>
        </Card>
      </div>
    </>
  );
}

function AccessModeButton({
  active,
  title,
  onClick,
}: {
  active: boolean;
  title: string;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={[
        "flex min-h-11 items-center justify-between rounded-md border px-3 py-2 text-left text-sm transition-colors",
        active
          ? "border-primary bg-primary/5 text-foreground"
          : "border-border hover:bg-muted/60",
      ].join(" ")}
    >
      <span>{title}</span>
      {active && <Check className="h-4 w-4 text-primary" />}
    </button>
  );
}

function CheckboxRow({
  checked,
  label,
  detail,
  onChange,
}: {
  checked: boolean;
  label: string;
  detail?: string;
  onChange: (checked: boolean) => void;
}) {
  return (
    <label className="flex cursor-pointer items-start gap-2 rounded-md px-2 py-1.5 text-sm transition-colors hover:bg-muted/60">
      <input
        type="checkbox"
        checked={checked}
        onChange={(e) => onChange(e.target.checked)}
        className="mt-0.5 h-4 w-4 rounded border-input"
      />
      <span className="min-w-0">
        <span className="block truncate">{label}</span>
        {detail && (
          <span className="block truncate font-mono text-xs text-muted-foreground">
            {detail}
          </span>
        )}
      </span>
    </label>
  );
}

function groupScopes(definitions: ScopeDefinition[]) {
  const groups = new Map<string, ScopeDefinition[]>();
  for (const definition of definitions) {
    groups.set(definition.group, [...(groups.get(definition.group) || []), definition]);
  }
  return Array.from(groups.entries());
}

function toggleValue(values: string[], value: string, checked: boolean) {
  if (checked) return Array.from(new Set([...values, value]));
  return values.filter((item) => item !== value);
}
