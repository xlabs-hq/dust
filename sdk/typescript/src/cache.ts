import type { BrowseOptions, Entry, Page } from './types'
import { match } from './glob'

export interface Cache {
  get(store: string, path: string): Entry | null
  readEntry(store: string, path: string): Entry | null
  readMany(store: string, paths: string[]): Record<string, Entry>
  set(store: string, path: string, entry: Entry): void
  delete(store: string, path: string): void
  deletePrefix(store: string, prefix: string): void
  entries(store: string, pattern: string): Entry[]
  browse(store: string, opts: BrowseOptions & { select: 'keys' | 'prefixes' }): Page<string>
  browse(store: string, opts: BrowseOptions & { select?: 'entries' }): Page<Entry>
  browse(store: string, opts: BrowseOptions): Page<Entry> | Page<string>
  lastSeq(store: string): number
  setLastSeq(store: string, seq: number): void
  clear(store: string): void
}

export class MemoryCache implements Cache {
  private stores = new Map<string, Map<string, Entry>>()
  private seqs = new Map<string, number>()

  private getStore(store: string): Map<string, Entry> {
    let s = this.stores.get(store)
    if (!s) {
      s = new Map()
      this.stores.set(store, s)
    }
    return s
  }

  get(store: string, path: string): Entry | null {
    return this.getStore(store).get(path) ?? null
  }

  readEntry(store: string, path: string): Entry | null {
    return this.stores.get(store)?.get(path) ?? null
  }

  readMany(store: string, paths: string[]): Record<string, Entry> {
    const storeMap = this.stores.get(store)
    if (!storeMap) return {}

    const result: Record<string, Entry> = {}
    const seen = new Set<string>()
    for (const path of paths) {
      if (seen.has(path)) continue
      seen.add(path)
      const entry = storeMap.get(path)
      if (entry) result[path] = entry
    }
    return result
  }

  set(store: string, path: string, entry: Entry): void {
    this.getStore(store).set(path, entry)
  }

  delete(store: string, path: string): void {
    this.getStore(store).delete(path)
  }

  deletePrefix(store: string, prefix: string): void {
    const s = this.getStore(store)
    for (const key of s.keys()) {
      if (key.startsWith(prefix)) {
        s.delete(key)
      }
    }
  }

  entries(store: string, pattern: string): Entry[] {
    const results: Entry[] = []
    for (const [path, entry] of this.getStore(store)) {
      if (match(pattern, path)) {
        results.push(entry)
      }
    }
    return results.sort((a, b) => a.path.localeCompare(b.path))
  }

  browse(store: string, opts: BrowseOptions & { select: 'keys' | 'prefixes' }): Page<string>
  browse(store: string, opts: BrowseOptions & { select?: 'entries' }): Page<Entry>
  browse(store: string, opts: BrowseOptions): Page<Entry> | Page<string>
  browse(store: string, opts: BrowseOptions): Page<Entry> | Page<string> {
    const pattern = opts.pattern ?? '**'
    const limit = opts.limit ?? 50
    const order = opts.order ?? 'asc'
    const select = opts.select ?? 'entries'

    // Validate prefixes pattern up front
    if (select === 'prefixes') {
      if (pattern !== '**' && !pattern.endsWith('.**')) {
        throw new Error('select: prefixes requires pattern ending in .** or **')
      }
    }

    const storeMap = this.stores.get(store)
    if (!storeMap) return { items: [], nextCursor: null }

    // KNOWN LIMITATION: walks the entire store Map on every call and filters in JS.
    // Acceptable for MVP — the in-memory cache is small and all ops are O(n) anyway.
    // If perf becomes an issue, add sorted indexes later.
    let entries: Entry[] = Array.from(storeMap.values())

    // Filter
    if (opts.from !== undefined && opts.to !== undefined) {
      // Range mode — skip glob filter entirely
      const from = opts.from
      const to = opts.to
      entries = entries.filter((e) => e.path >= from && e.path < to)
    } else {
      // Glob mode
      entries = entries.filter((e) => match(pattern, e.path))
    }

    // Sort
    entries.sort((a, b) =>
      order === 'asc' ? a.path.localeCompare(b.path) : b.path.localeCompare(a.path)
    )

    // Cursor
    if (opts.after !== undefined) {
      const after = opts.after
      entries =
        order === 'asc'
          ? entries.filter((e) => e.path > after)
          : entries.filter((e) => e.path < after)
    }

    // Take limit + 1 to detect next cursor
    const slice = entries.slice(0, limit + 1)
    const hasMore = slice.length > limit
    const pageItems = hasMore ? slice.slice(0, limit) : slice
    const nextCursor =
      hasMore && pageItems.length > 0 ? pageItems[pageItems.length - 1].path : null

    // Project
    if (select === 'entries') {
      return { items: pageItems, nextCursor }
    } else if (select === 'keys') {
      return { items: pageItems.map((e) => e.path), nextCursor }
    } else {
      // prefixes
      return { items: prefixesOf(pageItems, pattern), nextCursor }
    }
  }

  lastSeq(store: string): number {
    return this.seqs.get(store) ?? 0
  }

  setLastSeq(store: string, seq: number): void {
    this.seqs.set(store, seq)
  }

  clear(store: string): void {
    this.stores.delete(store)
    this.seqs.delete(store)
  }
}

function prefixesOf(entries: Entry[], pattern: string): string[] {
  const literal = literalPrefixOf(pattern)
  const seen = new Set<string>()
  for (const entry of entries) {
    const prefix = extractPrefix(entry.path, literal)
    if (prefix !== null) seen.add(prefix)
  }
  return Array.from(seen).sort()
}

function literalPrefixOf(pattern: string): string {
  if (pattern === '**') return ''
  return pattern.replace(/\.\*\*$/, '')
}

function extractPrefix(path: string, literal: string): string | null {
  if (literal === '') {
    const i = path.indexOf('.')
    return i === -1 ? path : path.slice(0, i)
  }
  const prefix = literal + '.'
  if (!path.startsWith(prefix)) return null
  const rest = path.slice(prefix.length)
  const i = rest.indexOf('.')
  return literal + '.' + (i === -1 ? rest : rest.slice(0, i))
}
