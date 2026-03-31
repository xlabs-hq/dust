import React, { useState } from "react";
import { Head, Link, router, usePage } from "@inertiajs/react";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { Label } from "@/components/ui/Label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/Select";
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from "@/components/ui/Card";
import type { SharedProps } from "@/types";
import { ArrowLeft } from "lucide-react";

interface StoreOption {
  id: string;
  name: string;
}

interface CreateTokenProps extends SharedProps {
  stores: StoreOption[];
  errors?: Record<string, string[]>;
}

export default function TokensCreate() {
  const { current_organization, stores, errors } =
    usePage<CreateTokenProps>().props;
  const orgSlug = current_organization?.slug || "";

  const [name, setName] = useState("");
  const [storeName, setStoreName] = useState("");
  const [read, setRead] = useState(true);
  const [write, setWrite] = useState(false);
  const [submitting, setSubmitting] = useState(false);

  const isValid = name.length > 0 && storeName.length > 0 && (read || write);

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!isValid) return;
    setSubmitting(true);
    router.post(
      `/${orgSlug}/tokens`,
      {
        name,
        store_name: storeName,
        read: String(read),
        write: String(write),
      },
      { onFinish: () => setSubmitting(false) }
    );
  }

  return (
    <>
      <Head title="Create Token" />
      <div className="space-y-6 max-w-lg">
        <div className="flex items-center gap-4">
          <Button variant="ghost" size="icon" asChild>
            <Link href={`/${orgSlug}/tokens`}>
              <ArrowLeft className="w-4 h-4" />
            </Link>
          </Button>
          <div>
            <h1 className="text-2xl font-semibold tracking-tight text-foreground">
              Create Token
            </h1>
            <p className="text-sm text-muted-foreground mt-1">
              Generate an API token for store access
            </p>
          </div>
        </div>

        {stores.length === 0 ? (
          <Card>
            <CardContent className="py-8 text-center">
              <p className="text-muted-foreground mb-4">
                You need at least one store before creating a token.
              </p>
              <Button asChild>
                <Link href={`/${orgSlug}/stores/new`}>Create a Store</Link>
              </Button>
            </CardContent>
          </Card>
        ) : (
          <Card>
            <form onSubmit={handleSubmit}>
              <CardHeader>
                <CardTitle>Token Details</CardTitle>
                <CardDescription>
                  Tokens provide API access to a specific store. The token
                  value will only be shown once after creation.
                </CardDescription>
              </CardHeader>
              <CardContent className="space-y-4">
                <div className="space-y-2">
                  <Label htmlFor="name">Token Name</Label>
                  <Input
                    id="name"
                    placeholder="e.g. production-api"
                    value={name}
                    onChange={(e) => setName(e.target.value)}
                    aria-invalid={errors?.name ? true : undefined}
                  />
                  {errors?.name && (
                    <p className="text-sm text-destructive">{errors.name[0]}</p>
                  )}
                </div>

                <div className="space-y-2">
                  <Label>Store</Label>
                  <Select value={storeName} onValueChange={setStoreName}>
                    <SelectTrigger className="w-full">
                      <SelectValue placeholder="Select a store" />
                    </SelectTrigger>
                    <SelectContent>
                      {stores.map((store) => (
                        <SelectItem key={store.id} value={store.name}>
                          {store.name}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>

                <fieldset className="space-y-3">
                  <Label asChild>
                    <legend>Permissions</legend>
                  </Label>
                  <div className="space-y-2">
                    <label className="flex items-center gap-2 text-sm cursor-pointer">
                      <input
                        type="checkbox"
                        checked={read}
                        onChange={(e) => setRead(e.target.checked)}
                        className="rounded border-input"
                      />
                      Read — can read entries and subscribe to changes
                    </label>
                    <label className="flex items-center gap-2 text-sm cursor-pointer">
                      <input
                        type="checkbox"
                        checked={write}
                        onChange={(e) => setWrite(e.target.checked)}
                        className="rounded border-input"
                      />
                      Write — can create, update, and delete entries
                    </label>
                  </div>
                </fieldset>
              </CardContent>
              <CardFooter className="flex justify-end gap-2">
                <Button variant="outline" asChild>
                  <Link href={`/${orgSlug}/tokens`}>Cancel</Link>
                </Button>
                <Button type="submit" disabled={!isValid || submitting}>
                  {submitting ? "Creating..." : "Create Token"}
                </Button>
              </CardFooter>
            </form>
          </Card>
        )}
      </div>
    </>
  );
}
