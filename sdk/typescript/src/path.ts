/**
 * Path utilities. Dust paths are dot-separated hierarchies, e.g.
 * "projects.alpha.title". Forward slashes are accepted as aliases for
 * dots — so `dust.put(store, "projects/alpha/title", v)` is equivalent
 * to `dust.put(store, "projects.alpha.title", v)`.
 *
 * Path segments cannot be empty. There is no escape for a literal `.`
 * in a key — keys with dots in their names are not supported.
 */

/**
 * Normalize a dotted-or-slashed path into the canonical dotted form.
 * Throws if the path is empty or contains empty segments.
 */
export function normalizePath(path: string): string {
  if (path === '') throw new Error('path cannot be empty')
  const canonical = path.replace(/\//g, '.')
  if (canonical.split('.').some((s) => s === '')) {
    throw new Error(`path "${path}" contains empty segments`)
  }
  return canonical
}

/**
 * Normalize a glob pattern. Slashes become dots; `*` and `**` are
 * valid segments.
 */
export function normalizePattern(pattern: string): string {
  if (pattern === '') throw new Error('pattern cannot be empty')
  const canonical = pattern.replace(/\//g, '.')
  if (canonical.split('.').some((s) => s === '')) {
    throw new Error(`pattern "${pattern}" contains empty segments`)
  }
  return canonical
}
