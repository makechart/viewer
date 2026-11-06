// 用 headless 瀏覽器跑 case. cli 的 run 與 serve 的 accept 共用, 所以 snapshot 一律出自同一種環境
// ( 同一個瀏覽器、viewport、DPR ). UI 所在的瀏覽器只拿來看, 不寫 snapshot.
const fs = require('fs'), path = require('path');

async function launch(o = {}) {
  const {chromium} = require('playwright-core');
  const base = {headless: !o.headed};
  if (o.browser && o.browser !== 'chrome') return chromium.launch({...base, executablePath: o.browser});
  if (o.browser === 'chrome') return chromium.launch({...base, channel: 'chrome'});
  try { return await chromium.launch(base); } catch (e) {
    // playwright 的 chromium 沒裝 ( 或版本對不上 ): 改用系統的 Chrome.
    // Chrome 會自動更新, 文字寬度可能因此有小數誤差 ( 見 near )
    return chromium.launch({...base, channel: 'chrome'});
  }
}

class Runner {
  constructor(o, port) { this.o = o; this.port = port; this.queue = Promise.resolve(); }

  async _open() {
    if (this.browser) return;
    this.browser = await launch(this.o);
    this.ctx = await this.browser.newContext({viewport: {width: 1600, height: 1000}, deviceScaleFactor: this.o.dpr || 2});
  }

  // opt: {grep} 或 {names: [...]} ( 完整名字 ). 每次都開新頁, 拿到 test/index.ls 的最新版
  run(opt = {}) {
    const job = this.queue.then(() => this._run(opt));
    this.queue = job.catch(() => {});
    return job;
  }

  async _run(opt) {
    await this._open();
    const page = this.page = await this.ctx.newPage();
    page.on('pageerror', e => console.error('[page error]', e.message));
    if (this.o.verbose) page.on('console', m => console.log('[page]', m.text()));
    await page.goto(`http://127.0.0.1:${this.port}/?headless`);
    await page.waitForFunction(() => window.mctest && mctest.ui && (mctest.ui.ready || mctest.ui.error), null, {timeout: 30000});
    const err = await page.evaluate(() => mctest.ui.error);
    if (err) throw new Error(err);
    const results = await page.evaluate((opt) => mctest.ui.run(opt), opt);
    if (opt.keepPage) return results;
    await page.close();
    this.page = null;
    return results;
  }

  // 失敗的 case 截圖 ( 要在 run 時帶 keepPage )
  async shot(file, dest) {
    if (!this.page) return;
    await this.page.locator(`.case[data-file="${file}"] .pane.current`).screenshot({path: dest}).catch(() => {});
  }

  async closePage() { if (this.page) await this.page.close(); this.page = null; }
  async close() { if (this.browser) await this.browser.close(); this.browser = null; }
}

function writeSnapshot(srv, r) {
  fs.mkdirSync(srv.snapDir, {recursive: true});
  fs.writeFileSync(path.join(srv.snapDir, r.file + '.html'), r.current);
}

module.exports = {Runner, launch, writeSnapshot};
