import type { Entry } from './types'
import { match } from './glob'

export interface Cache {
  get(store: string, path: string): Entry | null
  readEntry(store: string, path: string): Entry | null
  readMany(store: string, paths: string[]): Record<string, Entry>
  set(store: string, path: string, entry: Entry): void
  delete(store: string, path: string): void
  deletePrefix(store: string, prefix: string): void
  entries(store: string, pattern: string): Entry[]
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
