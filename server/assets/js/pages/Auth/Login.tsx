import React, { useState, FormEvent } from "react";
import { Head, Link } from "@inertiajs/react";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { Label } from "@/components/ui/Label";
import { ArrowLeft, Loader2 } from "lucide-react";
import { api } from "@/lib/api";
import { toast } from "sonner";

interface LoginProps {
  dev_bypass?: boolean;
}

type Step = "email" | "password" | "verify";

function Login({ dev_bypass }: LoginProps) {
  const [step, setStep] = useState<Step>("email");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [code, setCode] = useState("");
  const [pendingToken, setPendingToken] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  async function handleEmailSubmit(e: FormEvent) {
    e.preventDefault();
    setError("");
    setLoading(true);

    if (dev_bypass) {
      setStep("password");
      setLoading(false);
      return;
    }

    try {
      const { data } = await api.post<{ mode: string; redirect_url?: string }>(
        "/auth/check-email",
        { email }
      );

      if (data.mode === "sso" && data.redirect_url) {
        window.location.href = data.redirect_url;
      } else {
        setStep("password");
      }
    } catch {
      setStep("password");
    } finally {
      setLoading(false);
    }
  }

  async function handlePasswordSubmit(e: FormEvent) {
    e.preventDefault();
    setError("");
    setLoading(true);

    try {
      const { ok, data } = await api.post<{
        mode?: string;
        redirect_url?: string;
        redirect_to?: string;
        error?: string;
        requires_verification?: boolean;
        pending_authentication_token?: string;
      }>("/auth/sign-in", { email, password });

      if (data.requires_verification && data.pending_authentication_token) {
        setPendingToken(data.pending_authentication_token);
        setStep("verify");
        return;
      }

      if (!ok) {
        setError(data.error || "Invalid email or password.");
        return;
      }

      if (data.mode === "sso" && data.redirect_url) {
        window.location.href = data.redirect_url;
      } else {
        window.location.href = data.redirect_to || "/";
      }
    } catch {
      setError("Something went wrong. Please try again.");
    } finally {
      setLoading(false);
    }
  }

  async function handleVerify(e: FormEvent) {
    e.preventDefault();
    setError("");
    setLoading(true);

    try {
      const { ok, data } = await api.post<{
        error?: string;
        redirect_to?: string;
      }>("/auth/verify-email", { pending_authentication_token: pendingToken, code });

      if (!ok) {
        setError(data.error || "Invalid code. Please try again.");
        return;
      }

      window.location.href = data.redirect_to || "/";
    } catch {
      setError("Something went wrong. Please try again.");
    } finally {
      setLoading(false);
    }
  }

  function handleBack() {
    if (step === "verify") {
      setStep("password");
      setCode("");
    } else {
      setStep("email");
      setPassword("");
    }
    setError("");
  }

  return (
    <>
      <Head title="Sign in" />
      <div className="flex min-h-screen items-center justify-center bg-background">
        <div className="w-full max-w-sm space-y-8">
          <div className="text-center">
            <h1 className="text-4xl font-bold tracking-tight text-foreground">
              Dust
            </h1>
            <p className="mt-2 text-sm text-muted-foreground">
              {step === "verify"
                ? "Check your email for a verification code"
                : "Reactive state management for AI agents"}
            </p>
          </div>

          {step === "email" && (
            <form onSubmit={handleEmailSubmit} className="space-y-4">
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

              {error && (
                <p className="text-sm text-destructive">{error}</p>
              )}

              <Button type="submit" className="w-full" disabled={loading}>
                {loading && <Loader2 className="animate-spin" />}
                Continue
              </Button>

              {dev_bypass && (
                <a
                  href="/auth/authorize"
                  className="block text-center text-sm text-muted-foreground hover:text-foreground transition-colors"
                >
                  Dev Login (skip auth)
                </a>
              )}

              <p className="text-center text-sm text-muted-foreground">
                Don't have an account?{" "}
                <Link
                  href="/auth/register"
                  className="text-foreground underline-offset-4 hover:underline"
                >
                  Create one
                </Link>
              </p>
            </form>
          )}

          {step === "password" && (
            <form onSubmit={handlePasswordSubmit} className="space-y-4">
              <button
                type="button"
                onClick={handleBack}
                className="flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground transition-colors"
              >
                <ArrowLeft className="size-4" />
                {email}
              </button>

              <div className="space-y-2">
                <Label htmlFor="password">Password</Label>
                <Input
                  id="password"
                  type="password"
                  placeholder="Enter your password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  required
                  autoFocus
                  autoComplete="current-password"
                />
              </div>

              {error && (
                <p className="text-sm text-destructive">{error}</p>
              )}

              <Button type="submit" className="w-full" disabled={loading}>
                {loading && <Loader2 className="animate-spin" />}
                Sign in
              </Button>

              <p className="text-center text-sm text-muted-foreground">
                <Link
                  href="/auth/forgot-password"
                  className="text-foreground underline-offset-4 hover:underline"
                >
                  Forgot password?
                </Link>
              </p>
            </form>
          )}

          {step === "verify" && (
            <form onSubmit={handleVerify} className="space-y-4">
              <p className="text-sm text-muted-foreground">
                We sent a verification code to <strong>{email}</strong>.
              </p>

              <div className="space-y-2">
                <Label htmlFor="code">Verification code</Label>
                <Input
                  id="code"
                  type="text"
                  placeholder="Enter code"
                  value={code}
                  onChange={(e) => setCode(e.target.value)}
                  required
                  autoFocus
                  autoComplete="one-time-code"
                />
              </div>

              {error && (
                <p className="text-sm text-destructive">{error}</p>
              )}

              <Button type="submit" className="w-full" disabled={loading}>
                {loading && <Loader2 className="animate-spin" />}
                Verify and sign in
              </Button>

              <div className="flex items-center justify-between text-sm text-muted-foreground">
                <button
                  type="button"
                  onClick={handleBack}
                  className="inline-flex items-center gap-1 text-foreground underline-offset-4 hover:underline"
                >
                  <ArrowLeft className="size-4" />
                  Back
                </button>
                <button
                  type="button"
                  onClick={async () => {
                    // Re-authenticate to get a fresh pending token
                    const { data: d } = await api.post<{
                      pending_authentication_token?: string;
                    }>("/auth/sign-in", { email, password });
                    if (d.pending_authentication_token) {
                      setPendingToken(d.pending_authentication_token);
                    }
                    toast.success("Verification code resent");
                  }}
                  className="text-foreground underline-offset-4 hover:underline"
                >
                  Resend code
                </button>
              </div>
            </form>
          )}
        </div>
      </div>
    </>
  );
}

Login.layout = (page: React.ReactNode) => page;

export default Login;
