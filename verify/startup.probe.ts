/**
 * Standalone probe for the patched Web command-line provider.
 *
 * It runs the real `startup.ts` (plus the real `@deepseek-ai/dsh-cmdline`
 * source) against a fake Cordis context, so the `-pwd` flag plumbing is
 * observable without building the Harness monorepo.
 * Run: node --experimental-transform-types probe.ts
 */

import { internals } from '@deepseek-ai/dsh-cmdline'
import { apply, WEB_STARTUP_SERVICE, type WebStartupValues } from './startup.ts'

let failures = 0
let checks = 0

function check(label: string, condition: boolean, detail?: unknown): void {
  checks += 1
  if (condition) {
    console.log(`  ok   ${label}`)
    return
  }
  failures += 1
  console.log(`  FAIL ${label}${detail === undefined ? '' : ` => ${JSON.stringify(detail)}`}`)
}

interface Run {
  values: WebStartupValues | undefined
  exits: number[]
  out: string
}

/** Parse one inner argument list through the real provider. */
function boot(args: string[]): Run {
  const exits: number[] = []
  let out = ''
  internals.stdout = { write: (chunk: string) => { out += chunk; return true } }
  internals.stderr = { write: (chunk: string) => { out += chunk; return true } }
  let values: WebStartupValues | undefined
  const ctx = {
    get: (name: string) => {
      if (name === 'cmdlineArgs') return { get: () => args }
      if (name === 'appExit') return (code: number) => { exits.push(code) }
      return undefined
    },
    provide: (name: string, value: unknown) => {
      if (name === WEB_STARTUP_SERVICE) values = value as WebStartupValues
    },
  }
  apply(ctx as never)
  return { values, exits, out }
}

console.log('the -pwd spelling reaches the provider')
const short = boot(['-pwd', 'hunter2', '--no-open'])
check('the service is published', short.values !== undefined)
check('the password is the value that followed -pwd', short.values?.password === 'hunter2', short.values?.password)
check('no process exit was requested', short.exits.length === 0, short.exits)
check('--no-open still parses beside it', short.values?.openBrowser === false)

console.log('\nthe other spellings of the same flag')
check('-pwd=hunter2', boot(['-pwd=hunter2']).values?.password === 'hunter2')
check('-pwdhunter2', boot(['-pwdhunter2']).values?.password === 'hunter2')
check('--pwd hunter2', boot(['--pwd', 'hunter2']).values?.password === 'hunter2')
check('--pwd=hunter2', boot(['--pwd=hunter2']).values?.password === 'hunter2')
check('a flag order that puts -pwd last',
  boot(['--host', '127.0.0.1', '--port', '8080', '-pwd', 'hunter2']).values?.password === 'hunter2')

console.log('\nthe provider does not silently take the cluster apart')
const clustered = boot(['-pwd', 'hunter2'])
check('the password is not the tail of the flag text', clustered.values?.password !== 'wd', clustered.values?.password)
check('the value is never read as a leftover argument', clustered.exits.length === 0, clustered.exits)

console.log('\nstarting without -pwd is refused')
const missing = boot(['--no-open', '--port', '8080'])
check('the service is not published', missing.values === undefined)
check('the process is asked to exit with 1', missing.exits[0] === 1, missing.exits)
check('the error names the flag', missing.out.includes('-pwd <password> is required'), missing.out.trim().split('\n')[0])

console.log('\na too-short password is refused')
const shortLength = boot(['-pwd', 'abc'])
check('the service is not published', shortLength.values === undefined)
check('the process is asked to exit with 1', shortLength.exits[0] === 1, shortLength.exits)
check('the error names the minimum', shortLength.out.includes('at least 4 characters'), shortLength.out.trim().split('\n')[0])
check('four characters are enough', boot(['-pwd', 'abcd']).values?.password === 'abcd')

console.log('\nthe rest of the flag family is unchanged')
const wildcard = boot(['-pwd', 'hunter2', '--host', '0.0.0.0'])
check('a wildcard bind is still refused', wildcard.values === undefined && wildcard.exits[0] === 1)
const port = boot(['-pwd', 'hunter2', '--port', 'abc'])
check('a non-numeric port is still refused', port.values === undefined && port.exits[0] === 1)
const tls = boot(['-pwd', 'hunter2', '--tls-cert', 'server.pem'])
check('an unpaired TLS flag is still refused', tls.values === undefined && tls.exits[0] === 1)
const ok = boot(['-pwd', 'hunter2', '--host', '127.0.0.1', '--port', '8080', '--public-url', 'https://web.example/ui', '--trusted-host', 'lab.internal'])
check('the full family still publishes together', ok.values?.password === 'hunter2'
  && ok.values?.host === '127.0.0.1' && ok.values?.port === 8080
  && ok.values?.publicUrl === 'https://web.example/ui' && ok.values?.trustedHosts[0] === 'lab.internal')

console.log('\n--help still works and mentions the flag')
const help = boot(['--help'])
check('help exits 0', help.exits[0] === 0, help.exits)
check('help names -pwd', help.out.includes('-pwd'), help.out.slice(0, 0))
check('help names --pwd', help.out.includes('--pwd'))
check('no service is published by help', help.values === undefined)

console.log(`\n${String(checks - failures)}/${String(checks)} checks passed`)
if (failures > 0) process.exitCode = 1
