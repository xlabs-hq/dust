import React, { useState } from "react";
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
import { ArrowLeft } from "lucide-react";

interface CreateStoreProps extends SharedProps {
  errors?: Record<string, string[]>;
}

export default function StoresCreate() {
  const { current_organization, errors } = usePage<CreateStoreProps>().props;
  const orgSlug = current_organization?.slug || "";

  const [name, setName] = useState("");
  const [submitting, setSubmitting] = useState(false);

  const preview = name ? `${orgSlug}/${name}` : `${orgSlug}/...`;
  const namePattern = /^[a-z0-9][a-z0-9._-]*$/;
  const isValid = name.length > 0 && namePattern.test(name);

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!isValid) return;
    setSubmitting(true);
    router.post(`/${orgSlug}/stores`, { name }, {
      onFinish: () => setSubmitting(false),
    });
  }

  return (
    <>
      <Head title="Create Store" />
      <div className="space-y-6 max-w-lg">
        <div className="flex items-center gap-4">
          <Button variant="ghost" size="icon" asChild>
            <Link href={`/${orgSlug}/stores`}>
              <ArrowLeft className="w-4 h-4" />
            </Link>
          </Button>
          <div>
            <h1 className="text-2xl font-semibold tracking-tight text-foreground">
              Create Store
            </h1>
            <p className="text-sm text-muted-foreground mt-1">
              Add a new data store to your organization
            </p>
          </div>
        </div>

        <Card>
          <form onSubmit={handleSubmit}>
            <CardHeader>
              <CardTitle>Store Details</CardTitle>
              <CardDescription>
                Store names must be lowercase and can contain letters, numbers,
                dots, hyphens, and underscores.
              </CardDescription>
            </CardHeader>
            <CardContent className="space-y-4">
              <div className="space-y-2">
                <Label htmlFor="name">Store Name</Label>
                <Input
                  id="name"
                  placeholder="my-store"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  aria-invalid={errors?.name ? true : undefined}
                />
                {errors?.name && (
                  <p className="text-sm text-destructive">{errors.name[0]}</p>
                )}
              </div>

              <div className="rounded-md bg-muted p-3">
                <p className="text-xs text-muted-foreground mb-1">
                  Full store name
                </p>
                <p className="font-mono text-sm text-foreground">{preview}</p>
              </div>
            </CardContent>
            <CardFooter className="flex justify-end gap-2">
              <Button variant="outline" asChild>
                <Link href={`/${orgSlug}/stores`}>Cancel</Link>
              </Button>
              <Button type="submit" disabled={!isValid || submitting}>
                {submitting ? "Creating..." : "Create Store"}
              </Button>
            </CardFooter>
          </form>
        </Card>
      </div>
    </>
  );
}
