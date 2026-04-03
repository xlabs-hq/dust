# `dust init` Design

Zero-config project setup. Detects TypeScript project, creates store, generates token, writes `.env`, prints example code. One command, zero to working.

## Flow

1. Check auth (bail with "run `dust login` first" if not authenticated)
2. Detect project: look for `package.json` in current directory
3. Derive store name from `package.json` `name` field, or directory name
4. Derive org from the authenticated token's organization
5. Create store via `POST /api/stores` with the derived name
6. Generate a read/write token via `POST /api/tokens` for the new store
7. Write `.env` file with `DUST_URL` and `DUST_API_KEY`
8. Print example TypeScript code snippet

## CLI

```
dust init [--store name] [--org org] [--ttl seconds]
```

All flags optional. Smart defaults for everything.

## Output

```
Detected TypeScript project: my-app

Created store: myorg/my-app
Generated token: dust_tok_abc...

Wrote .env:
  DUST_URL=wss://app.dust.dev/ws/sync
  DUST_API_KEY=dust_tok_abc...

Get started:

  import { Dust } from '@dust-sync/sdk'

  const dust = new Dust({
    url: process.env.DUST_URL,
    token: process.env.DUST_API_KEY,
  })

  await dust.put('myorg/my-app', 'hello', 'world')
  const value = await dust.get('myorg/my-app', 'hello')
```

## Edge Cases

- No `package.json`: error with "No TypeScript/Node.js project found. Run from a project directory."
- `.env` already exists: append, don't overwrite. Skip keys that already exist.
- Store already exists: use it (the API returns 422 for name taken — catch and continue).
- Token already in `.env`: skip token generation, print "already configured."
- Not authenticated: error with "Run `dust login` first."

## Deferred

- Elixir project detection (mix.exs)
- Installing the SDK dependency (`npm install @dust-sync/sdk`)
- Multiple store support
