/**
 * Centralized API client using fetch.
 * Reads CSRF token fresh from the meta tag on every request.
 */

function getCsrfToken(): string | null {
  return document
    .querySelector('meta[name="csrf-token"]')
    ?.getAttribute("content") ?? null;
}

interface ApiOptions extends Omit<RequestInit, "body"> {
  body?: Record<string, unknown>;
}

interface ApiResponse<T = unknown> {
  ok: boolean;
  status: number;
  data: T;
}

async function request<T = unknown>(
  url: string,
  options: ApiOptions = {}
): Promise<ApiResponse<T>> {
  const { body, headers: extraHeaders, ...rest } = options;

  const headers: Record<string, string> = {
    "Accept": "application/json",
    ...(extraHeaders as Record<string, string>),
  };

  const csrfToken = getCsrfToken();
  if (csrfToken) {
    headers["x-csrf-token"] = csrfToken;
  }

  if (body) {
    headers["Content-Type"] = "application/json";
  }

  const response = await fetch(url, {
    ...rest,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });

  let data: T;
  const contentType = response.headers.get("content-type");
  if (contentType?.includes("application/json")) {
    data = await response.json();
  } else {
    data = (await response.text()) as unknown as T;
  }

  return { ok: response.ok, status: response.status, data };
}

export const api = {
  get: <T = unknown>(url: string) => request<T>(url, { method: "GET" }),

  post: <T = unknown>(url: string, body?: Record<string, unknown>) =>
    request<T>(url, { method: "POST", body }),

  put: <T = unknown>(url: string, body?: Record<string, unknown>) =>
    request<T>(url, { method: "PUT", body }),

  delete: <T = unknown>(url: string) => request<T>(url, { method: "DELETE" }),
};
