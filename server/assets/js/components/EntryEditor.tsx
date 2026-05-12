import React from "react";
import { toast } from "sonner";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/Dialog";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { Label } from "@/components/ui/Label";

export interface EntryEditorProps {
  /** "create" = path editable, value empty. "edit" = path locked, value pre-filled. */
  mode: "create" | "edit";
  /** Open/close state. Lifted so the caller can also trigger from row actions. */
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** API endpoint base — `/api/stores/:org/:store/entries`. */
  endpoint: string;
  /** Path being edited (edit mode only). Ignored in create mode. */
  path?: string;
  /** Initial value (edit mode); undefined in create mode. */
  initialValue?: unknown;
  /** Fired on successful write so the page can refresh / reconcile. */
  onSaved?: (path: string) => void;
}

// Body-path UI writes go to the new POST /entries route. The server
// accepts `{path, value}` and rejects empty paths / missing value with
// 400. The slashed `PUT /entries/<path>` route still exists — we just
// prefer the body variant from the browser because it's friendlier
// with dotted paths.
export function EntryEditor({
  mode,
  open,
  onOpenChange,
  endpoint,
  path,
  initialValue,
  onSaved,
}: EntryEditorProps) {
  const [pathInput, setPathInput] = React.useState("");
  const [valueText, setValueText] = React.useState("");
  const [submitting, setSubmitting] = React.useState(false);
  const [valueError, setValueError] = React.useState<string | null>(null);

  // Reset state every time the modal opens so a "Cancel" + "Edit
  // different row" sequence doesn't leak stale fields.
  React.useEffect(() => {
    if (!open) return;
    setSubmitting(false);
    setValueError(null);

    if (mode === "edit" && path !== undefined) {
      setPathInput(path);
      setValueText(JSON.stringify(initialValue ?? null, null, 2));
    } else {
      setPathInput("");
      setValueText("");
    }
  }, [open, mode, path, initialValue]);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setValueError(null);

    const trimmedPath = pathInput.trim();
    if (!trimmedPath) {
      setValueError("Path is required.");
      return;
    }

    let parsedValue: unknown;
    try {
      parsedValue = valueText.trim() === "" ? null : JSON.parse(valueText);
    } catch (err) {
      setValueError(
        `Value must be valid JSON (${err instanceof Error ? err.message : "parse error"}).`,
      );
      return;
    }

    setSubmitting(true);

    try {
      const csrfToken = readCsrfToken();
      const res = await fetch(endpoint, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "content-type": "application/json",
          accept: "application/json",
          ...(csrfToken ? { "x-csrf-token": csrfToken } : {}),
        },
        body: JSON.stringify({ path: trimmedPath, value: parsedValue }),
      });

      if (!res.ok) {
        const body = await res.json().catch(() => ({}));
        const message =
          body.error ||
          body.detail ||
          `Write failed (HTTP ${res.status})`;
        toast.error(message);
        setSubmitting(false);
        return;
      }

      toast.success(mode === "edit" ? "Entry updated" : "Entry created");
      onSaved?.(trimmedPath);
      onOpenChange(false);
    } catch (err) {
      toast.error(
        err instanceof Error ? err.message : "Network error — please retry",
      );
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <form onSubmit={handleSubmit} className="space-y-4">
          <DialogHeader>
            <DialogTitle>
              {mode === "edit" ? "Edit entry" : "New entry"}
            </DialogTitle>
            <DialogDescription>
              {mode === "edit"
                ? "Path is fixed — writes upsert the value at this path."
                : "Enter a dotted path and any JSON value. Submit upserts."}
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-2">
            <Label htmlFor="entry-path">Path</Label>
            <Input
              id="entry-path"
              value={pathInput}
              onChange={(e) => setPathInput(e.target.value)}
              readOnly={mode === "edit"}
              placeholder="users.alice.email"
              className="font-mono"
              autoComplete="off"
            />
          </div>

          <div className="space-y-2">
            <Label htmlFor="entry-value">Value (JSON)</Label>
            <textarea
              id="entry-value"
              value={valueText}
              onChange={(e) => setValueText(e.target.value)}
              rows={8}
              className="font-mono text-sm w-full rounded-md border border-input bg-background px-3 py-2 placeholder:text-muted-foreground focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none"
              placeholder={`"a string"\n42\n{"nested": true}`}
              spellCheck={false}
              autoComplete="off"
            />
            {valueError && (
              <p className="text-sm text-destructive">{valueError}</p>
            )}
          </div>

          <DialogFooter>
            <Button
              type="button"
              variant="ghost"
              onClick={() => onOpenChange(false)}
              disabled={submitting}
            >
              Cancel
            </Button>
            <Button type="submit" disabled={submitting}>
              {submitting ? "Saving..." : "Save"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

function readCsrfToken(): string | null {
  if (typeof document === "undefined") return null;
  const meta = document.querySelector('meta[name="csrf-token"]');
  return meta ? meta.getAttribute("content") : null;
}
