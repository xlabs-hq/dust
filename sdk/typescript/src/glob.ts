export function match(pattern: string, path: string): boolean {
  const patternParts = pattern.split('.')
  const pathParts = path.split('.')
  return matchParts(patternParts, pathParts, 0, 0)
}

function matchParts(pattern: string[], path: string[], pi: number, pa: number): boolean {
  // Both exhausted = match
  if (pi === pattern.length && pa === path.length) return true
  // Pattern exhausted but path not = no match
  if (pi === pattern.length) return false
  // Path exhausted but pattern not = no match (** requires at least one segment)
  if (pa === path.length) {
    return false
  }

  const seg = pattern[pi]

  if (seg === '**') {
    // ** matches one or more segments
    // Try consuming 1, 2, 3, ... path segments
    for (let skip = 1; skip <= path.length - pa; skip++) {
      if (matchParts(pattern, path, pi + 1, pa + skip)) return true
    }
    return false
  }

  if (seg === '*') {
    // * matches exactly one segment
    return matchParts(pattern, path, pi + 1, pa + 1)
  }

  // Literal match
  if (seg === path[pa]) {
    return matchParts(pattern, path, pi + 1, pa + 1)
  }

  return false
}
