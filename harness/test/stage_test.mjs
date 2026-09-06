// Serve the same install files as the release without starting a fleet.
import assert from 'node:assert/strict'
import { mkdtemp, copyFile, writeFile, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { Stage, ROOT } from '../src/stage.mjs'

const dir = await mkdtemp(path.join(tmpdir(), 'vw-manifest-'))
const page = path.join(dir, 'index.html')
const stage = new Stage({ page })
try {
  await writeFile(page, '<html><body>test game</body></html>')
  const assets = [
    ['manifest.webmanifest', 'application/manifest+json'],
    ['icon-192.png', 'image/png'],
    ['icon-512.png', 'image/png']
  ]
  for (const [name] of assets) {
    await copyFile(path.join(ROOT, 'client/web', name), path.join(dir, name))
  }
  await stage.servePage()
  for (const [name, type] of assets) {
    const response = await fetch(new URL(name, stage.pageUrl))
    assert.equal(response.status, 200)
    assert.equal(response.headers.get('content-type'), type)
    assert.deepEqual(Buffer.from(await response.arrayBuffer()),
      await readFile(path.join(dir, name)))
  }
  assert.equal(await (await fetch(stage.pageUrl)).text(), await readFile(page, 'utf8'))
  const report = { kind: 'test', message: 'diagnostics still work' }
  const response = await fetch(new URL('meta/v1/client-error', stage.pageUrl), {
    method: 'POST', body: JSON.stringify(report)
  })
  assert.equal(response.status, 204)
  assert.equal(stage.clientErrors[0].message, report.message)
  console.log('ok: harness serves the page, manifest, icons, and diagnostics')
} finally {
  await stage.down()
  await rm(dir, { recursive: true, force: true })
}
