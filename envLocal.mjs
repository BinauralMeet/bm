//  Loads .env.local (KEY=VALUE per line, gitignored) into process.env if present, without
//  overwriting anything already set. Used by smoke.mjs/repro-avatar.mjs so the committed
//  scripts only ever contain placeholder hostnames/endpoints -- the real per-host values for
//  this sandbox live in .env.local, which is never committed.
import {readFileSync, existsSync} from 'node:fs'
import {fileURLToPath} from 'node:url'

const envPath = fileURLToPath(new URL('.env.local', import.meta.url))
if (existsSync(envPath)) {
  for (const line of readFileSync(envPath, 'utf8').split('\n')) {
    const m = line.match(/^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/)
    if (m) process.env[m[1]] ??= m[2]
  }
}
