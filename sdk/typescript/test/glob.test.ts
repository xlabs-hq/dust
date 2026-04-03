import { describe, it, expect } from 'vitest'
import { match } from '../src/glob'

describe('glob', () => {
  it('matches exact path', () => {
    expect(match('users.alice.name', 'users.alice.name')).toBe(true)
  })

  it('rejects non-matching path', () => {
    expect(match('users.alice.name', 'users.bob.name')).toBe(false)
  })

  it('* matches one segment', () => {
    expect(match('users.*', 'users.alice')).toBe(true)
    expect(match('users.*', 'users.alice.name')).toBe(false)
    expect(match('users.*.name', 'users.alice.name')).toBe(true)
  })

  it('** matches one or more segments', () => {
    expect(match('users.**', 'users.alice')).toBe(true)
    expect(match('users.**', 'users.alice.name')).toBe(true)
    expect(match('users.**', 'users.alice.profile.avatar')).toBe(true)
  })

  it('** does not match zero segments', () => {
    expect(match('users.**', 'users')).toBe(false)
  })

  it('handles pattern at different positions', () => {
    expect(match('**.name', 'users.alice.name')).toBe(true)
    expect(match('users.**.email', 'users.alice.email')).toBe(true)
    expect(match('users.**.email', 'users.alice.profile.email')).toBe(true)
  })

  it('rejects empty path', () => {
    expect(match('users.*', '')).toBe(false)
  })

  it('matches single segment exactly', () => {
    expect(match('config', 'config')).toBe(true)
    expect(match('config', 'other')).toBe(false)
  })
})
