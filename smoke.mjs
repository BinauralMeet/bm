//  CDP smoke test against the running dev server: loads the app through the sandbox reverse
//  proxy in the host's headful debug Chrome, joins a room, opens the left bar's status dialog
//  and screenshots it. Run:
//      sandbox exec -- bash -lc 'node /home/hase/sandhome/bm/smoke.mjs'
//
//  This file lives outside either repo, so resolve playwright out of the client's node_modules
//  explicitly (ESM resolution is relative to the importing file, not cwd).
import {createRequire} from 'node:module'
const {chromium} = createRequire('/home/hase/sandhome/bm/binaural-meet/')('playwright')

const CDP = 'http://172.17.0.1:20001'
//  No skipEntrance: that only suppresses the entrance dialog, and conference.enter() is called
//  from TheEntrance's own onClose (or testBot mode), so skipping it means never connecting at
//  all. The bot goes through the same dialog a human does.
const URL = 'https://ai1.haselab.net/sandbox/port3000/?room=smoke&name=smokebot'
const OUT = '/home/hase/sandhome/bm/logs'

const browser = await chromium.connectOverCDP(CDP)
const ctx = browser.contexts()[0] ?? await browser.newContext()
//  Failed earlier runs leave their tabs (and their WebRTC transports, which mediasoup only has
//  50 UDP ports for) open in the shared headful Chrome; close them so each run starts clean --
//  but open the new tab first, since closing the last one shuts Chrome down.
const stale = ctx.pages()
const page = await ctx.newPage()
for (const p of stale) { await p.close().catch(()=>{}) }

try {
  const log = []
  page.on('console', m => { if (m.type() === 'error' || m.type() === 'warning') log.push(`[${m.type()}] ${m.text()}`) })
  page.on('pageerror', e => log.push(`[pageerror] ${e.message}`))
  page.on('requestfailed', r => log.push(`[reqfail] ${r.url()} ${r.failure()?.errorText}`))
  page.on('response', r => { if (r.status() >= 300) log.push(`[http ${r.status()}] ${r.url()}`) })
  page.on('websocket', ws => {
    log.push(`[ws open] ${ws.url()}`)
    ws.on('socketerror', e => log.push(`[ws error] ${ws.url()} ${e}`))
    ws.on('close', () => log.push(`[ws close] ${ws.url()}`))
  })

  await page.goto(URL, {waitUntil: 'domcontentloaded', timeout: 60000})

  //  Entrance dialog -> fill a name (the Enter button stays disabled while it is empty) and enter.
  await page.locator('#entrance-name').fill('smokebot', {timeout: 30000})
  await page.screenshot({path: `${OUT}/smoke-entrance.png`})
  await page.getByRole('button', {name: /Enter the venue/i}).click({timeout: 15000})
  await page.waitForTimeout(25000)
  await page.screenshot({path: `${OUT}/smoke-app.png`})

  //  Dismiss the error dialog if one is up, otherwise it swallows clicks on the map/left bar.
  for (const label of ['Never show this in this session', 'Close']) {
    const b = page.getByRole('button', {name: label})
    if (await b.count() && await b.first().isVisible()) { await b.first().click().catch(()=>{}); break }
  }
  await page.waitForTimeout(1000)

  //  The status dialog opens by clicking the left bar's "<N> in <room>" title.
  let auto = 'not opened'
  try {
    await page.getByText(/\d+ in /).first().click({timeout: 10000})
    await page.waitForTimeout(1500)
    auto = await page.getByText(/Auto:/).first().innerText({timeout: 10000})
  } catch (e) {
    auto = `FAILED: ${e.message.split('\n')[0]}`
  }
  await page.screenshot({path: `${OUT}/smoke-status.png`})

  console.log('--- Auto line ---\n' + auto)
  console.log('--- log (%d entries) ---', log.length)
  console.log(log.slice(0, 40).join('\n'))
} finally {
  //  Always leave the room/close the tab, even if an assertion above threw -- otherwise this
  //  run's participant stays joined forever, holding WebRTC transports (see the stale-tab sweep
  //  above for why that matters).
  await page.close().catch(()=>{})
  await browser.close().catch(()=>{})
}
