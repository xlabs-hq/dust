import React, { useState, FormEvent } from "react";
import { Head, Link } from "@inertiajs/react";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { Label } from "@/components/ui/Label";
import { Loader2, ArrowLeft } from "lucide-react";
import { api } from "@/lib/api";

function ForgotPassword() {
  const [email, setEmail] = useState("");
  const [sent, setSent] = useState(false);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setLoading(true);

    try {
      await api.post("/auth/forgot-password", { email });
    } catch {
      // Always show success to avoid leaking accounts
    }

    setSent(true);
    setLoading(false);
  }

  return (
    <>
      <Head title="Reset password" />
      <div className="flex min-h-screen items-center justify-center bg-background">
        <div className="w-full max-w-sm space-y-8">
          <div className="text-center">
            <h1 className="text-4xl font-bold tracking-tight text-foreground">
              Dust
            </h1>
            <p className="mt-2 text-sm text-muted-foreground">
              Reset your password
            </p>
          </div>

          {sent ? (
            <div className="space-y-4 text-center">
              <p className="text-sm text-muted-foreground">
                If an account exists for <strong>{email}</strong>, we've sent a
                password reset link. Check your email.
              </p>
              <Link
                href="/auth/login"
                className="inline-flex items-center gap-1 text-sm text-foreground underline-offset-4 hover:underline"
              >
                <ArrowLeft className="size-4" />
                Back to sign in
              </Link>
            </div>
          ) : (
            <form onSubmit={handleSubmit} className="space-y-4">
              <div className="space-y-2">
                <Label htmlFor="email">Email</Label>
                <Input
                  id="email"
                  type="email"
                  placeholder="you@example.com"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  required
                  autoFocus
                  autoComplete="email"
                />
              </div>

              <Button type="submit" className="w-full" disabled={loading}>
                {loading && <Loader2 className="animate-spin" />}
                Send reset link
              </Button>

              <p className="text-center text-sm text-muted-foreground">
                <Link
                  href="/auth/login"
                  className="inline-flex items-center gap-1 text-foreground underline-offset-4 hover:underline"
                >
                  <ArrowLeft className="size-4" />
                  Back to sign in
                </Link>
              </p>
            </form>
          )}
        </div>
      </div>
    </>
  );
}

ForgotPassword.layout = (page: React.ReactNode) => page;

export default ForgotPassword;
