// mctest server: 在受測 chart 的 repo ( cwd ) 裡起一個 http server.
//
//  /                         engine 的 UI ( web/index.html )
//  /engine/<file>            engine 的前端檔案 ( <name>.js 由 src/<name>.ls 即時編譯, 其餘在 web/ )
//  /assets/lib/<name>/<ver>/<path>
//                            前端依賴, 規則同 makechart server / fedep ( 版本一律忽略, 用找到的那份 ):
//                              1. -l 指定的本地目錄 ( 有 dist/ 先找 dist/ )
//                              2. 受測的 chart 自己 ( package.json name -> cwd/dist )
//                              3. node_modules ( 先 cwd 再 engine 自己的 ), 含 npm link 的 symlink
//  /test/index.js            chart 的 test case ( test/index.ls 即時編譯, 或 test/index.js )
//  /test/<path>              chart 的 test/ 目錄 ( 放資料檔用 )
//  /api/info                 {name, version, links}
//  GET /api/snapshot/<name>  讀 test/snapshot/<name>.html ( 沒有回 204 )
//  POST /api/accept {names}  用 headless 重跑這些 case 並存成 snapshot ( serve 才有, 見 bin/cli.js )
const http = require('http'), fs = require('fs'), path = require('path');

const engineRoot = path.resolve(__dirname, '..');
const types = {
  '.js': 'application/javascript', '.css': 'text/css', '.html': 'text/html', '.json': 'application/json',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.csv': 'text/csv', '.woff2': 'font/woff2', '.txt': 'text/plain'
};

// "name:dir;name:dir" ( 同 fedep -l ) -> {name: absdir}
function parseLinks(s) {
  const ret = {};
  (s || '').split(';').map(v => v.trim()).filter(v => v).forEach(v => {
    const i = v.lastIndexOf(':');
    if (i <= 0) throw new Error(`[mctest] bad link spec: ${v} ( expect name:dir )`);
    ret[v.slice(0, i)] = path.resolve(v.slice(i + 1).replace(/^~/, require('os').homedir()));
  });
  return ret;
}

function findModule(name, from) {
  for (let d = from; ; d = path.dirname(d)) {
    const p = path.join(d, 'node_modules', name);
    if (fs.existsSync(path.join(p, 'package.json'))) return p;
    if (d === path.dirname(d)) return null;
  }
}

function isFile(f) { try { return fs.statSync(f).isFile(); } catch (e) { return false; } }

function create(opt = {}) {
  const cwd = path.resolve(opt.cwd || '.');
  const pkg = JSON.parse(fs.readFileSync(path.join(cwd, 'package.json')));
  const links = Object.assign({}, opt.links || {});
  const testDir = path.join(cwd, opt.testDir || 'test');
  const snapDir = path.join(testDir, 'snapshot');

  // 一個模組可能的根目錄, 依序嘗試
  const roots = (name) => {
    const dev = (d) => [path.join(d, 'dist'), d];
    if (links[name]) return dev(links[name]);
    if (name === pkg.name) return dev(cwd);
    const ret = [];
    for (const from of [cwd, engineRoot]) {
      const m = findModule(name, from);
      if (m) ret.push(m, path.join(m, 'dist'));
    }
    return ret;
  };
  const resolveLib = (name, rest) => {
    for (const r of roots(name)) {
      const f = path.join(r, rest);
      if (!f.startsWith(r + path.sep)) return null;
      if (isFile(f)) return f;
      // block 的 path 可以是目錄 ( 例如 @plotdb/konfig 的 base ), 同 registry 補 index.html
      if (isFile(path.join(f, 'index.html'))) return path.join(f, 'index.html');
    }
    return null;
  };

  // <name>.js 由 src/<name>.ls 即時編譯 ( 依 mtime 快取 ), 開發 engine 時改了重新整理即生效
  const compiled = {};
  const engineFile = (p) => {
    const src = /^[\w-]+\.js$/.test(p) && path.join(engineRoot, 'src', p.replace(/\.js$/, '.ls'));
    if (src && isFile(src)) {
      const m = fs.statSync(src).mtimeMs;
      if (!compiled[p] || compiled[p].m !== m) {
        compiled[p] = {m, code: require('livescript').compile(fs.readFileSync(src, 'utf8'), {filename: src})};
      }
      return {body: compiled[p].code, type: types['.js']};
    }
    const f = path.join(engineRoot, 'web', p);
    if (!f.startsWith(path.join(engineRoot, 'web') + path.sep) || !isFile(f)) return null;
    return {file: f};
  };

  const caseFile = () => {
    const ls = path.join(testDir, 'index.ls'), js = path.join(testDir, 'index.js');
    if (isFile(ls)) return require('livescript').compile(fs.readFileSync(ls, 'utf8'), {filename: ls});
    if (isFile(js)) return fs.readFileSync(js, 'utf8');
    return 'console.warn("[mctest] no test/index.ls or test/index.js found")';
  };

  const snapName = (n) => {
    if (!/^[\w.=,+@-]+$/.test(n)) return null;
    return path.join(snapDir, n + '.html');
  };

  const send = (res, code, body, type) => {
    res.writeHead(code, {'Content-Type': type || 'text/plain; charset=utf-8', 'Cache-Control': 'no-store'});
    res.end(body);
  };
  const sendFile = (res, f) => {
    res.writeHead(200, {'Content-Type': types[path.extname(f)] || 'application/octet-stream', 'Cache-Control': 'no-store'});
    fs.createReadStream(f).pipe(res);
  };

  const handle = (req, res) => {
    let p;
    try { p = decodeURIComponent(req.url.split('?')[0]); } catch (e) { return send(res, 400, 'bad url'); }
    let m;
    if (p === '/' || p === '/index.html') return sendFile(res, path.join(engineRoot, 'web', 'index.html'));
    if ((m = /^\/engine\/(.+)$/.exec(p))) {
      let r;
      try { r = engineFile(m[1]); } catch (e) { return send(res, 500, String(e.stack || e)); }
      if (!r) return send(res, 404, 'not found');
      return r.file ? sendFile(res, r.file) : send(res, 200, r.body, r.type);
    }
    if ((m = /^\/assets\/lib\/((?:@[^/]+\/)?[^/]+)\/[^/]+\/(.+)$/.exec(p))) {
      const f = resolveLib(m[1], m[2]);
      if (!f) { if (opt.verbose) console.log('[mctest] 404', p); return send(res, 404, 'not found'); }
      return sendFile(res, f);
    }
    if (p === '/test/index.js') {
      try { return send(res, 200, caseFile(), types['.js']); } catch (e) {
        return send(res, 200, `console.error(${JSON.stringify('[mctest] compile test case failed:\n' + (e.stack || e))})`, types['.js']);
      }
    }
    if (p === '/api/info') {
      return send(res, 200, JSON.stringify({name: pkg.name, version: pkg.version, links}), types['.json']);
    }
    if ((m = /^\/api\/snapshot\/(.+)$/.exec(p))) {
      const f = snapName(m[1]);
      if (!f) return send(res, 400, 'bad name');
      // 沒有 snapshot 回 204 而不是 404, 免得瀏覽器 console 每個新 case 都噴一行錯
      return isFile(f) ? sendFile(res, f) : send(res, 204, '');
    }
    if (p === '/api/accept' && req.method === 'POST') {
      if (!api.accept) return send(res, 501, 'accept is only available in `mctest serve`');
      const buf = [];
      req.on('data', d => buf.push(d));
      req.on('end', () => {
        let names;
        try { names = JSON.parse(Buffer.concat(buf).toString()).names; } catch (e) { return send(res, 400, 'bad body'); }
        api.accept(names)
          .then(r => send(res, 200, JSON.stringify(r), types['.json']))
          .catch(e => send(res, 500, String(e.stack || e)));
      });
      return;
    }
    if ((m = /^\/test\/(.+)$/.exec(p))) {
      const f = path.join(testDir, m[1]);
      if (f.startsWith(testDir + path.sep) && isFile(f)) return sendFile(res, f);
      return send(res, 404, 'not found');
    }
    send(res, 404, 'not found');
  };

  const server = http.createServer(handle);
  const api = {
    server, pkg, cwd, links, snapDir, testDir,
    listen: (port) => new Promise((res, rej) => {
      server.once('error', rej);
      server.listen(port || 0, '127.0.0.1', () => res(server.address().port));
    }),
    close: () => new Promise(res => server.close(res))
  };
  return api;
}

module.exports = {create, parseLinks};
