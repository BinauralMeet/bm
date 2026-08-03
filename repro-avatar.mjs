//  Checks the two 3D-avatar bugs against the running dev server, in the host's headful debug
//  Chrome:  (1) the avatar chooser list stays empty (CORS),  (2) the avatar-URL field keeps
//  only the file name, destroying the URL in the store.
//  Run:  sandbox exec -- bash -lc 'node /home/hase/sandhome/bm/repro-avatar.mjs'
import {createRequire} from 'node:module'
const {chromium} = createRequire('/home/hase/sandhome/bm/binaural-meet/')('playwright')

const URL = 'https://ai1.haselab.net/sandbox/port3000/?room=smoke&name=avatarbot'
const OUT = '/home/hase/sandhome/bm/logs'
const PASTED = 'https://binaural.me/public_packages/uploader/vrm/avatar/maid.vrm'

const browser = await chromium.connectOverCDP('http://172.17.0.1:20001')
const ctx = browser.contexts()[0] ?? await browser.newContext()
//  Failed earlier runs leave their tabs (and their WebRTC transports, which mediasoup only has
//  50 UDP ports for) open in the shared headful Chrome; close them so each run starts clean --
//  but open the new tab first, since closing the last one shuts Chrome down.
const stale = ctx.pages()
const page = await ctx.newPage()
for (const p of stale) { await p.close().catch(()=>{}) }

try {
const log = []
page.on('console', m => { if (m.type() === 'error') log.push(`[console] ${m.text()}`) })
page.on('requestfailed', r => log.push(`[reqfail] ${r.url()} ${r.failure()?.errorText}`))
page.on('response', r => { if (r.status() >= 400) log.push(`[http ${r.status()}] ${r.url()}`) })

await page.goto(URL, {waitUntil: 'domcontentloaded', timeout: 60000})
await page.evaluate(() => localStorage.removeItem('localParticipantInformation'))
await page.locator('#entrance-name').fill('avatarbot', {timeout: 30000})
await page.getByRole('button', {name: /Enter the venue/i}).click({timeout: 15000})
await page.locator('#entrance-name').waitFor({state: 'detached', timeout: 30000})
await page.waitForTimeout(10000)

//  Open the local participant's settings form from the left bar. Right click, not left --
//  left just focuses the map on that participant.
await page.getByRole('button', {name: 'avatarbot'}).first().click({button: 'right', timeout: 15000})
await page.waitForTimeout(2000)

//  (2) Paste a full avatar URL, force a re-render by tabbing away, then save and read back what
//  actually landed in the store (saveInformationToStorage writes it to localStorage).
//  MUI's InputLabel isn't associated with the input, so getByLabel can't find it. The form has
//  exactly two text inputs: [0] the name, [1] "Gravatar's email or VRM's URL".
const email = page.locator('input[type=text]').nth(1)
await email.fill(PASTED, {timeout: 10000})
const shownRightAfter = await email.inputValue()
await page.keyboard.press('Tab')
await page.waitForTimeout(1500)
const shownAfterRerender = await email.inputValue()
//  The paste alone isn't what loses the URL -- the field re-renders showing only the file name,
//  and it is the NEXT edit that writes that abbreviated text back over the stored URL. Type a
//  character and delete it again to trigger exactly that, without otherwise changing the value.
await email.click()
await page.keyboard.press('End')
await page.keyboard.type('x')
await page.keyboard.press('Backspace')
await page.waitForTimeout(1000)
const shownAfterEdit = await email.inputValue()

//  (1) Open the 3D avatar chooser and see whether any thumbnail shows up.
await page.getByRole('button', {name: /^3D$/}).first().click({timeout: 10000})
await page.waitForTimeout(20000)
await page.screenshot({path: `${OUT}/repro-3dlist.png`})
const thumbs = await page.locator('img[alt=loading]').count()
const rendered = await page.locator('img[alt=loading]').evaluateAll(
  imgs => imgs.filter(i => i.src.startsWith('data:')).length)
const chooserError = await page.locator('div[style*="color: red"]').allInnerTexts()

//  Pick the first avatar in the list (that closes the chooser); if the list is empty, close the
//  chooser by hand -- while it is open its popover covers the form's "Save and close".
if (thumbs) {
  await page.locator('img[alt=loading]').first().click({force: true, timeout: 10000})
} else {
  await page.getByRole('button', {name: /^Close$/i}).first().click({timeout: 10000})
}
await page.waitForTimeout(1000)
await page.getByRole('button', {name: /Save and close/i}).click({timeout: 10000})
await page.waitForTimeout(8000)
const stored = await page.evaluate(() => {
  const raw = localStorage.getItem('localParticipantInformation')
  const info = raw ? JSON.parse(raw) : {}
  return {email: info.email, avatarSrc: info.avatarSrc}
})
await page.screenshot({path: `${OUT}/repro-after.png`})

//  The picked VRM only appears on the map once 3D display is on (config.js has it off by
//  default); this is what exercises loadVrmAvatar() in models/utils/vrm.ts.
//  The tooltip title isn't exposed as an accessible name, so go by position in the footer:
//  Fab3DSettings is the first FAB there.
await page.locator('.MuiFab-root').first().click({timeout: 10000})
await page.waitForTimeout(20000)
await page.screenshot({path: `${OUT}/repro-3don.png`})

console.log('pasted            :', PASTED)
console.log('shown right after :', shownRightAfter)
console.log('shown re-rendered :', shownAfterRerender)
console.log('shown after edit  :', shownAfterEdit)
console.log('thumbnails        :', thumbs, '(rendered:', rendered + ')')
console.log('chooser error     :', JSON.stringify(chooserError))
console.log('stored email      :', stored.email)
console.log('stored avatarSrc  :', stored.avatarSrc)
console.log('--- log (%d) ---\n%s', log.length, log.slice(0, 20).join('\n'))
} finally {
  //  Always leave the room/close the tab, even if an assertion above threw -- otherwise this
  //  run's participant stays joined forever, holding WebRTC transports (see the stale-tab sweep
  //  above for why that matters).
  await page.close().catch(()=>{})
  await browser.close().catch(()=>{})
}
