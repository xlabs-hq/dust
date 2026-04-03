import type { Entry } from './types'
import { match } from './glob'

export interface Cache {
  get(store: string, path: string): Entry | null
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
