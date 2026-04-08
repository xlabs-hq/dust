import React, { useState, FormEvent } from "react";
import { Head, Link } from "@inertiajs/react";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { Label } from "@/components/ui/Label";
import { ArrowLeft, Loader2 } from "lucide-react";
import { api } from "@/lib/api";
import { toast } from "sonner";

type Step = "register" | "verify";

function Register() {
  const [step, setStep] = useState<Step>("register");
  const [firstName, setFirstName] = useState("");
  const [lastName, setLastName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [code, setCode] = useState("");
  const [pendingToken, setPendingToken] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  async function handleRegister(e: FormEvent) {
    e.preventDefault();
    setError("");
    setLoading(true);

    try {
      const { ok, data } = await api.post<{
        error?: string;
        redirect_to?: string;
        requires_verification?: boolean;
        pending_authentication_token?: string;
      }>("/auth/sign-up", {
        email,
        password,
        first_name: firstName || undefined,
        last_name: lastName || undefined,
      });

      if (data.requires_verification && data.pending_authentication_token) {
        setPendingToken(data.pending_authentication_token);
        setStep("verify");
        return;
      }

      if (!ok) {
        setError(data.error || "Something went wrong. Please try again.");
        return;
      }

      window.location.href = data.redirect_to || "/";
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

  return (
    <>
      <Head title={step === "verify" ? "Verify email" : "Create account"} />
      <div className="flex min-h-screen items-center justify-center bg-background">
        <div className="w-full max-w-sm space-y-8">
          <div className="text-center">
            <h1 className="text-4xl font-bold tracking-tight text-foreground">
              Dust
            </h1>
            <p className="mt-2 text-sm text-muted-foreground">
              {step === "verify"
                ? "Check your email for a verification code"
                : "Create your account"}
            </p>
          </div>

          {step === "verify" ? (
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
                  onClick={() => {
                    setStep("register");
                    setError("");
                  }}
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
                    }>("/auth/sign-up", { email, password });
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
          ) : (
            <form onSubmit={handleRegister} className="space-y-4">
              <div className="grid grid-cols-2 gap-4">
                <div className="space-y-2">
                  <Label htmlFor="first_name">First name</Label>
                  <Input
                    id="first_name"
                    type="text"
                    placeholder="Jane"
                    value={firstName}
                    onChange={(e) => setFirstName(e.target.value)}
                    autoComplete="given-name"
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="last_name">Last name</Label>
                  <Input
                    id="last_name"
                    type="text"
                    placeholder="Doe"
                    value={lastName}
                    onChange={(e) => setLastName(e.target.value)}
                    autoComplete="family-name"
                  />
                </div>
              </div>

              <div className="space-y-2">
                <Label htmlFor="email">Email</Label>
                <Input
                  id="email"
                  type="email"
                  placeholder="you@example.com"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  required
                  autoComplete="email"
                />
              </div>

              <div className="space-y-2">
                <Label htmlFor="password">Password</Label>
                <Input
                  id="password"
                  type="password"
                  placeholder="At least 8 characters"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  required
                  minLength={8}
                  autoComplete="new-password"
                />
              </div>

              {error && (
                <p className="text-sm text-destructive">{error}</p>
              )}

              <Button type="submit" className="w-full" disabled={loading}>
                {loading && <Loader2 className="animate-spin" />}
                Create account
              </Button>

              <p className="text-center text-sm text-muted-foreground">
                Already have an account?{" "}
                <Link
                  href="/auth/login"
                  className="text-foreground underline-offset-4 hover:underline"
                >
                  Sign in
                </Link>
              </p>
            </form>
          )}
        </div>
      </div>
    </>
  );
}

Register.layout = (page: React.ReactNode) => page;

export default Register;
