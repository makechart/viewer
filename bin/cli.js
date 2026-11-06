#!/usr/bin/env node
// mctest - makechart 圖表的 test suite. 在 chart repo 的根目錄執行:
//
//   npx mctest                 headless 跑全部 case, 跟 test/snapshot 比對. 沒有 snapshot 的會直接存起來
//   npx mctest -u              不一致的也直接更新 snapshot
//   npx mctest -g stack        只跑名字含 stack 的 ( 也可以是 regexp )
//   npx mctest serve [-o]      開 UI 看圖、比對、accept ( accept 時用 headless 重跑再存 )
//
// 共用選項:
//   -l name:dir[;name:dir]     本地目錄取代 node_modules 裡的版本 ( 同 fedep -l, 有 dist/ 用 dist/ )
//                              也可以用環境變數 MCTEST_LINK
//   -p port                    serve 的 port ( 預設 8722 ), run 預設隨機
//   --ci                       沒有 snapshot 的 case 算失敗, 不自動存
//   --browser chrome|<path>    指定瀏覽器. 預設用 playwright 的 chromium, 沒裝就用系統的 Chrome
//   --loose                    數字差在 tolerance 內 ( near ) 也算過. 預設不算: 真的差 1px 的改動也要抓到
//   --dpr n                    headless 的 devicePixelRatio ( 預設 2, 同 Mac 螢幕 ). 文字寬度會隨它有小數誤差
//   --headed                   run 時顯示瀏覽器視窗
//   -v                         印出 404 與頁面的 console
const fs = require('fs'), path = require('path');
const {create, parseLinks} = require('../lib/server');
const {Runner, writeSnapshot} = require('../lib/runner');

function parseArgs(argv) {
  const o = {cmd: 'run', links: {}, grep: '', update: false, ci: false, loose: false, dpr: 2, headed: false, verbose: false, open: false};
  const links = [process.env.MCTEST_LINK || ''];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i], next = () => argv[++i];
    if (a === 'serve' || a === 'run') o.cmd = a;
    else if (a === '-u' || a === '--update') o.update = true;
    else if (a === '-g' || a === '--grep') o.grep = next();
    else if (a === '-l' || a === '--link') links.push(next());
    else if (a === '-p' || a === '--port') o.port = +next();
    else if (a === '-o' || a === '--open') o.open = true;
    else if (a === '--ci') o.ci = true;
    else if (a === '--loose') o.loose = true;
    else if (a === '--dpr') o.dpr = +next();
    else if (a === '--browser') o.browser = next();
    else if (a === '--headed') o.headed = true;
    else if (a === '-v' || a === '--verbose') o.verbose = true;
    else if (a === '-h' || a === '--help') o.cmd = 'help';
    else { console.error(`[mctest] unknown option: ${a}`); process.exit(2); }
  }
  o.links = parseLinks(links.join(';'));
  return o;
}

async function run(o, srv) {
  const port = await srv.listen(o.port);
  const outDir = path.join(srv.testDir, 'output');
  fs.rmSync(outDir, {recursive: true, force: true});
  const runner = new Runner(o, port);
  let code = 0;
  try {
    const results = await runner.run({grep: o.grep, keepPage: true});
    const cnt = {};
    for (const r of results) {
      let s = r.status;
      if (s === 'near' && !o.loose) s = 'diff';
      if (s === 'diff' && o.update) s = 'updated';
      else if (s === 'new' && !o.ci) s = 'added';
      cnt[s] = (cnt[s] || 0) + 1;
      if (s === 'updated' || s === 'added') writeSnapshot(srv, r);
      if (['diff', 'new', 'error'].includes(s)) {
        // 失敗的留下目前的 markup 跟截圖 ( 給 CI 當 artifact ), 對照用 serve 看比較方便
        fs.mkdirSync(outDir, {recursive: true});
        if (r.current) fs.writeFileSync(path.join(outDir, r.file + '.html'), r.current);
        await runner.shot(r.file, path.join(outDir, r.file + '.png'));
        code = 1;
      }
      const mark = {pass: '✓', near: '≈', updated: '↻', added: '+', skip: '-', diff: '✗', new: '✗', error: '✗'}[s];
      const note = s === 'pass' ? '' : `  ( ${r.status}${r.status === 'near' ? ` ±${r.delta}` : ''}${s !== r.status ? ` -> ${s}` : ''} )`;
      if (!['pass', 'near'].includes(s) || o.verbose) console.log(` ${mark} ${r.name}${note}`);
      if (s === 'diff' || s === 'updated') console.log(`     line ${r.line}\n     - ${r.expect}\n     + ${r.actual}`);
      if (s === 'new') console.log('     no snapshot ( run without --ci to save it )');
      if (s === 'error') console.log('     ' + String(r.error).split('\n').slice(0, 4).join('\n     '));
    }
    console.log(`\n${results.length} cases: ` + Object.entries(cnt).map(([k, v]) => `${k} ${v}`).join(', '));
    if (code) console.log(`\n失敗的 case 輸出在 ${path.relative(process.cwd(), outDir)}/. 用 \`npx mctest serve\` 對照, 確認沒問題再 \`npx mctest -u\``);
  } finally {
    await runner.close();
    await srv.close();
  }
  return code;
}

async function serve(o, srv) {
  const port = await srv.listen(o.port || 8722);
  // UI 的 accept: 用 headless 重跑那幾個 case 再存, 不收 UI 所在瀏覽器畫的版本
  const runner = new Runner(o, port);
  srv.accept = async (names) => {
    const rs = await runner.run({names});
    rs.filter(r => r.current).forEach(r => writeSnapshot(srv, r));
    return rs.map(r => ({name: r.name, file: r.file, status: r.current ? 'saved' : r.status, error: r.error}));
  };
  const url = `http://localhost:${port}/`;
  console.log(`[mctest] ${srv.pkg.name} -> ${url}`);
  for (const [k, v] of Object.entries(srv.links)) console.log(`[mctest] link ${k} -> ${v}`);
  if (o.open) {
    const cmd = process.platform === 'darwin' ? 'open' : process.platform === 'win32' ? 'start' : 'xdg-open';
    require('child_process').exec(`${cmd} ${url}`);
  }
}

const o = parseArgs(process.argv.slice(2));
if (o.cmd === 'help') {
  console.log(fs.readFileSync(__filename, 'utf8').split('\n').slice(1).filter(l => l.startsWith('//')).map(l => l.slice(3)).join('\n'));
  process.exit(0);
}
if (!fs.existsSync('package.json')) { console.error('[mctest] run it in the root of a chart repo ( package.json not found )'); process.exit(2); }
const srv = create({links: o.links, verbose: o.verbose});
(o.cmd === 'serve' ? serve(o, srv) : run(o, srv).then(c => process.exit(c)))
  .catch(e => { console.error(e.stack || e); process.exit(1); });
