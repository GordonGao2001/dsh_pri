/**
 * Standalone probe for the patched BrowserAuth password gate.
 *
 * It runs the real `browser-auth.ts` against fake request/response objects so
 * the gate's behavior is observable without building the Harness monorepo.
 * Run: node --experimental-transform-types probe.ts
 */

import { BrowserAuth, MIN_PASSWORD_LENGTH, PASSWORD_LOGIN_PATH } from './browser-auth.ts'

const PASSWORD = 'hunter2-hunter2'

interface FakeResponse {
  status: number
  headers: Record<string, string>
  body: string | undefined
  writeHead(status: number, headers?: Readonly<Record<string, string>>): FakeResponse
  end(body?: string): FakeResponse
}

function response(): FakeResponse {
  const res: FakeResponse = {
    status: 0,
    headers: {},
    body: undefined,
    writeHead(status, headers) {
      res.status = status
      res.headers = headers === undefined ? {} : { ...headers }
      return res
    },
    end(body) {
      res.body = body
      return res
    },
  }
  return res
}

interface FakeRequest {
  method: string
  url: string
  headers: Record<string, string>
  socket: { remoteAddress: string }
  [Symbol.asyncIterator](): AsyncIterator<Uint8Array>
}

function request(options: {
  method?: string
  url?: string
  host?: string
  address?: string
  forwardedFor?: string
  cookie?: string
  body?: string
}): FakeRequest {
  const headers: Record<string, string> = { host: options.host ?? '127.0.0.1:3080' }
  if (options.forwardedFor !== undefined) headers['cf-connecting-ip'] = options.forwardedFor
  if (options.cookie !== undefined) headers.cookie = options.cookie
  const body = Buffer.from(options.body ?? '', 'utf8')
  return {
    method: options.method ?? 'GET',
    url: options.url ?? '/',
    headers,
    socket: { remoteAddress: options.address ?? '127.0.0.1' },
    async *[Symbol.asyncIterator]() {
      if (body.byteLength > 0) yield body
    },
  }
}

/** Credential provider stub: stores one grant record in memory. */
function credentials(): { modifyRecord(key: string, update: (current: unknown) => Promise<unknown>): Promise<unknown> } {
  let stored: unknown
  return {
    async modifyRecord(_key, update) {
      const next = await update(stored)
      if (next !== undefined) stored = next
      return stored
    },
  }
}

let failures = 0
let checks = 0

function check(label: string, condition: boolean, detail?: unknown): void {
  checks += 1
  if (condition) {
    console.log(`  ok   ${label}`)
    return
  }
  failures += 1
  console.log(`  FAIL ${label}${detail === undefined ? '' : ` ${JSON.stringify(detail)}`}`)
}

async function auth(): Promise<BrowserAuth> {
  return await BrowserAuth.create({}, credentials() as never, 30, PASSWORD)
}

function sessionCookieOf(res: FakeResponse): string {
  const raw = res.headers['set-cookie']
  if (raw === undefined) throw new Error('no set-cookie')
  const end = raw.indexOf(';')
  return end < 0 ? raw : raw.slice(0, end)
}

async function main(): Promise<void> {
  console.log('short password rejected')
  let refused = false
  try {
    await BrowserAuth.create({}, credentials() as never, 30, 'ab')
  } catch (error) {
    refused = error instanceof Error && error.message.includes(String(MIN_PASSWORD_LENGTH))
  }
  check('a password shorter than the minimum fails the load', refused)

  console.log('\nno session: the password page is served, never the application')
  const gate = await auth()
  const anonymous = response()
  const allowed = gate.authorizeIndex(request({}), anonymous)
  check('authorizeIndex refuses', allowed === false)
  check('the page is served with 200', anonymous.status === 200, anonymous.status)
  check('the page is HTML', anonymous.headers['content-type']?.startsWith('text/html') === true)
  check('the page carries the login form', anonymous.body?.includes(`action=".${PASSWORD_LOGIN_PATH}"`) === true)
  check('the page asks for -pwd', anonymous.body?.includes('-pwd') === true)
  check('no credential is cached', anonymous.headers['cache-control'] === 'no-store')
  check('no session cookie is set', anonymous.headers['set-cookie'] === undefined)

  console.log('\nthe launch-token query parameter is gone')
  const tokenised = response()
  const tokenAllowed = gate.authorizeIndex(request({ url: '/?token=anything-at-all' }), tokenised)
  check('a ?token= request is not authenticated', tokenAllowed === false)
  check('it receives the password page', tokenised.status === 200 && tokenised.body?.includes('<form') === true)

  console.log('\nwrong password')
  const wrong = response()
  await gate.handleLogin(request({ method: 'POST', url: PASSWORD_LOGIN_PATH, body: 'password=wrong' }), wrong)
  check('401', wrong.status === 401, wrong.status)
  check('no cookie', wrong.headers['set-cookie'] === undefined)
  check('the page still asks for a password', wrong.body?.includes('<form') === true)

  console.log('\nright password binds the first address')
  const first = response()
  await gate.handleLogin(request({ method: 'POST', url: PASSWORD_LOGIN_PATH, body: `password=${PASSWORD}` }), first)
  check('303 redirect', first.status === 303, first.status)
  check('redirect target is the application', first.headers.location === './', first.headers.location)
  check('Set-Cookie is HttpOnly', first.headers['set-cookie']?.includes('HttpOnly') === true)
  check('Set-Cookie is SameSite', first.headers['set-cookie']?.includes('SameSite=') === true)
  check('the address is bound', gate.boundSourceAddress === '127.0.0.1', gate.boundSourceAddress)
  const cookie = sessionCookieOf(first)

  console.log('\nthe session serves the application to the bound address')
  const served = response()
  check('authorizeIndex allows it', gate.authorizeIndex(request({ cookie }), served) === true)
  check('no page was written', served.status === 0, served.status)
  check('the /api trust check allows it', gate.isAuthenticated(request({ cookie })) === true)

  console.log('\nanother address is refused even with the right password and the cookie')
  const other = { address: '127.0.0.2' }
  const foreignCookie = response()
  check('the cookie is useless from another address',
    gate.authorizeIndex(request({ cookie, ...other }), foreignCookie) === false)
  check('that request is refused with 403', foreignCookie.status === 403, foreignCookie.status)
  check('the /api trust check refuses it too', gate.isAuthenticated(request({ cookie, ...other })) === false)
  const foreignLogin = response()
  await gate.handleLogin(
    request({ method: 'POST', url: PASSWORD_LOGIN_PATH, body: `password=${PASSWORD}`, ...other }),
    foreignLogin,
  )
  check('the right password from another address is refused', foreignLogin.status === 403, foreignLogin.status)
  check('no cookie for the foreign address', foreignLogin.headers['set-cookie'] === undefined)
  check('the binding did not move', gate.boundSourceAddress === '127.0.0.1', gate.boundSourceAddress)

  console.log('\nthe same address may log in again and out of the tunnel view')
  const again = response()
  await gate.handleLogin(request({ method: 'POST', url: PASSWORD_LOGIN_PATH, body: `password=${PASSWORD}` }), again)
  check('303', again.status === 303, again.status)

  console.log('\na tunnel reports the real client in a forwarded header')
  const tunnelled = await auth()
  const tunnelLogin = response()
  await tunnelled.handleLogin(request({
    method: 'POST',
    url: PASSWORD_LOGIN_PATH,
    body: `password=${PASSWORD}`,
    forwardedFor: '203.0.113.9',
  }), tunnelLogin)
  check('the tunnel client binds its own address', tunnelled.boundSourceAddress === '203.0.113.9', tunnelled.boundSourceAddress)
  const tunnelCookie = sessionCookieOf(tunnelLogin)
  check('the tunnel client is served', tunnelled.authorizeIndex(
    request({ cookie: tunnelCookie, forwardedFor: '203.0.113.9' }), response()) === true)
  check('the tunnel hop itself is not', tunnelled.authorizeIndex(
    request({ cookie: tunnelCookie }), response()) === false)
  check('a different tunnel client is not', tunnelled.authorizeIndex(
    request({ cookie: tunnelCookie, forwardedFor: '198.51.100.7' }), response()) === false)
  check('a forged header from a remote peer is ignored', await (async () => {
    const remote = await auth()
    const res = response()
    await remote.handleLogin(request({
      method: 'POST',
      url: PASSWORD_LOGIN_PATH,
      body: `password=${PASSWORD}`,
      address: '10.1.2.3',
      forwardedFor: '203.0.113.9',
    }), res)
    return remote.boundSourceAddress === '10.1.2.3'
  })())

  console.log('\nIPv4-mapped and IPv6 loopback peers')
  const mapped = await auth()
  const mappedRes = response()
  await mapped.handleLogin(request({
    method: 'POST',
    url: PASSWORD_LOGIN_PATH,
    body: `password=${PASSWORD}`,
    address: '::ffff:127.0.0.1',
    forwardedFor: '198.51.100.7',
  }), mappedRes)
  check('an IPv4-mapped loopback peer counts as loopback', mapped.boundSourceAddress === '198.51.100.7',
    mapped.boundSourceAddress)
  const mappedCookie = sessionCookieOf(mappedRes)
  check('its session works for the same forwarded client', mapped.isAuthenticated(
    request({ cookie: mappedCookie, address: '::ffff:127.0.0.1', forwardedFor: '198.51.100.7' })) === true)
  check('and not for the plain loopback peer', mapped.isAuthenticated(
    request({ cookie: mappedCookie, address: '127.0.0.1' })) === false)

  const v6 = await auth()
  const v6Res = response()
  await v6.handleLogin(request({
    method: 'POST',
    url: PASSWORD_LOGIN_PATH,
    body: `password=${PASSWORD}`,
    address: '::1',
    forwardedFor: '2001:db8::5',
  }), v6Res)
  check('an IPv6 loopback peer counts as loopback', v6.boundSourceAddress === '2001:db8::5', v6.boundSourceAddress)

  console.log('\nother endpoints of the login route')
  const get = response()
  await gate.handleLogin(request({ method: 'GET', url: PASSWORD_LOGIN_PATH }), get)
  check('GET serves the form', get.status === 200 && get.body?.includes('<form') === true)
  const put = response()
  await gate.handleLogin(request({ method: 'PUT', url: PASSWORD_LOGIN_PATH }), put)
  check('PUT is 405', put.status === 405, put.status)
  const json = response()
  const jsonAuth = await auth()
  await jsonAuth.handleLogin(request({ method: 'POST', url: PASSWORD_LOGIN_PATH, body: JSON.stringify({ password: PASSWORD }) }), json)
  check('a JSON submission is accepted', json.status === 303, json.status)

  console.log('\nno source address at all')
  const addressless = await auth()
  const noSocket = { ...request({}), socket: {} }
  const addresslessRes = response()
  check('a request without a peer address is refused',
    addressless.authorizeIndex(noSocket, addresslessRes) === false)
  check('with 403', addresslessRes.status === 403, addresslessRes.status)

  console.log('\na tampered cookie')
  const tampered = response()
  check('a modified cookie is refused', gate.authorizeIndex(request({ cookie: `${cookie}x` }), tampered) === false)
  check('an unsigned cookie is refused', gate.authorizeIndex(request({ cookie: 'dsh-auth-x=v2.abc.def' }), response()) === false)

  console.log('\nan expired session')
  const shortLived = await BrowserAuth.create({}, credentials() as never, 1, PASSWORD)
  const expiring = response()
  await shortLived.handleLogin(request({ method: 'POST', url: PASSWORD_LOGIN_PATH, body: `password=${PASSWORD}` }), expiring)
  const expiringCookie = sessionCookieOf(expiring)
  const realNow = Date.now
  Date.now = () => realNow() + 2 * 24 * 60 * 60 * 1000
  check('an expired cookie is refused', shortLived.isAuthenticated(request({ cookie: expiringCookie })) === false)
  Date.now = realNow

  console.log(`\n${String(checks - failures)}/${String(checks)} checks passed`)
  if (failures > 0) process.exitCode = 1
}

await main()
