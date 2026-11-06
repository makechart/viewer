# mctest - makechart 圖表的 test suite engine ( 瀏覽器端 )
#
# chart 的 test/index.ls 用 `mctest.suite {...}` 宣告 case, engine 負責:
#  - 每個 case 建一個新的 chart 實例 ( 或一個 @plotdb/dash board ), 套資料與設定, 跑 steps
#  - 動畫一律切到 manual 再 flush 到終點, 所以輸出跟機器快慢無關
#  - 把圖的 DOM 正規化成 markup ( 數字取到小數兩位、一個 tag 一行 ), 跟 test/snapshot 比對
#
# 一個 case:
#   name     唯一的名字, 也是 snapshot 的檔名
#   data     suite.data 裡的名字, 或直接給 {raw, binding}
#   config   chart.config 的內容 ( 會跟 suite.config 深層合併 )
#   size     [w, h] px, 預設 suite.size
#   steps    [(chart, ctx) -> ...] 依序執行, 每步之後等畫面穩定. 可回傳 promise
#            ctx.snap(label) 在當下多存一格 ( 預設只存最後的樣子 ). ctx.root 是這個 case 的容器
#   dash     {def, size} 用 @plotdb/dash 的 board 跑多張圖 ( 測 crossfilter ).
#            此時 steps 拿到的是 (board, ctx), ctx.chart(id) 取得某個 panel 的圖
#   skip     true 時略過
#
# suite 層級: data, cases, config, size, chart ( 預設是 package.json 的 name ), normalize ( [[regexp, 取代字串]] ),
#           tolerance ( 數字容許的誤差, 預設 1 ), quiet ( DOM 多久沒變算穩定, 預設 250ms ). 這兩個 case 也可以各自設

mctest = {cases: [], suites: []}

registry = ({url, name, version, path, type}) ->
  if url => return url
  if type == \block => return "/assets/lib/#name/#{version or \main}/#{path or \index.html}"
  "/assets/lib/#name/#{version or \main}/#{path or (if type == \css => \index.min.css else \index.min.js)}"

mctest.manager = mgr = new block.manager {registry}

# ---------------------------------------------------------------- helpers

mctest.merge = merge = (a = {}, ...bs) ->
  for b in bs => for k, v of (b or {}) =>
    a[k] = if v and typeof(v) == \object and !Array.isArray(v) =>
      merge (if a[k] and typeof(a[k]) == \object and !Array.isArray(a[k]) => a[k] else {}), v
    else v
  a

# 參數的所有組合: combo {type: <[column bar]>, multiple: <[stack group]>}
# -> [{type: \column, multiple: \stack}, ...] 共 4 組
mctest.combo = (o = {}) ->
  ret = [{}]
  for k, vs of o =>
    nxt = []
    for r in ret => for v in vs =>
      c = {} <<< r
      c[k] = v
      nxt.push c
    ret = nxt
  ret

# 組合轉成名字: {type: \column, multiple: \stack} -> "type=column,multiple=stack"
mctest.label = (o = {}) -> ["#k=#v" for k, v of o].join \,

# 固定種子的亂數 ( 產生測試資料用, 每次都一樣 )
mctest.random = (seed = 1) ->
  s = seed .>>>. 0
  -> (s := (1664525 * s + 1013904223) .>>>. 0) / 4294967296

mctest.file = (n) -> n.replace /[^\w.=,+@-]+/g, \_

wait = (t = 0) -> new Promise (res) -> setTimeout res, t

# 模擬拖曳 ( 例如 brush ). p0 / p1 是 node 內的相對座標 ( 0 ~ 1 )
mctest.drag = (node, p0, p1, n = 6) ->
  r = node.getBoundingClientRect!
  pt = ([x, y]) -> {clientX: r.left + r.width * x, clientY: r.top + r.height * y}
  opt = {bubbles: true, cancelable: true, pointerId: 1, isPrimary: true, button: 0, buttons: 1}
  node.dispatchEvent new PointerEvent \pointerdown, ({} <<< opt <<< pt p0)
  for i from 1 to n =>
    p = [p0.0 + (p1.0 - p0.0) * i / n, p0.1 + (p1.1 - p0.1) * i / n]
    window.dispatchEvent new PointerEvent \pointermove, ({} <<< opt <<< pt p)
  window.dispatchEvent new PointerEvent \pointerup, ({} <<< opt <<< pt(p1) <<< {buttons: 0})
  node.dispatchEvent new MouseEvent \click, ({bubbles: true, cancelable: true} <<< pt p1)

# ---------------------------------------------------------------- normalize

# 每次執行都會變的東西, 換成固定字串. 圖表若有自己的亂數 id, 在 suite.normalize 裡補
volatile = [
  # ldview 的 scope 屬性名字是亂數
  [/ld-scope-ld-[a-z0-9]+/g, \ld-scope-ld-x]
  # @plotdb/chart 的 legend id ( Math.random )
  [/(pdlg-[a-z]+-)[a-z0-9]+(-)/g, '$1x$2']
]

# DOM -> markup. 自己序列化而不用 innerHTML: 屬性依名字排序 ( 設定順序會隨執行順序變, 例如頁面上
# 第一張圖跟之後的不同 ), 一個 tag 一行方便 diff. 產生的 markup 可以直接塞回 innerHTML 重現畫面
void-tags = <[area base br col embed hr img input link meta source track wbr]>
esc-attr = (v) -> v.replace(/&/g, \&amp;).replace(/"/g, \&quot;).replace(/</g, \&lt;)
esc-text = (v) -> v.replace(/&/g, \&amp;).replace(/</g, \&lt;).replace(/>/g, \&gt;)
mctest.serialize = serialize = (root) ->
  out = []
  walk = (n) ->
    if n.nodeType == 3 =>
      if (t = n.textContent.trim!) => out.push esc-text(t)
      return
    if n.nodeType != 1 => return
    tag = n.tagName
    if !n.namespaceURI or n.namespaceURI == "http://www.w3.org/1999/xhtml" => tag = tag.toLowerCase!
    attrs = Array.from(n.attributes)
      .map -> [it.name, it.value]
      .sort (a, b) -> if a.0 < b.0 => -1 else if a.0 > b.0 => 1 else 0
      .map ([k, v]) -> " #k=\"#{esc-attr v}\""
      .join ''
    out.push "<#tag#attrs>"
    if tag in void-tags => return
    Array.from(n.childNodes).map walk
    out.push "</#tag>"
  Array.from(root.childNodes).map walk
  out.join \\n

# 數字取到小數兩位 ( 去掉尾端 0 )
mctest.normalize = normalize = (node, extra = []) ->
  html = serialize node
  for [re, v] in volatile ++ extra => html = html.replace re, v
  html
    .replace /-?\d+\.\d+(e-?\d+)?/g, (m) ->
      v = +(+m).toFixed(2)
      if v == 0 => \0 else String(v)

sep = (label) -> "<!-- mctest:snap #label -->"
mctest.join-snaps = (snaps) -> snaps.map((s) -> "#{sep s.label}\n#{s.markup}").join("\n")
mctest.split-snaps = (text) ->
  ret = []
  text.split(/^<!-- mctest:snap (.*?) -->$/m).slice(1).map (v, i, a) ->
    if i % 2 == 0 => ret.push {label: v, markup: (a[i + 1] or '').trim!}
  ret

# ---------------------------------------------------------------- settle

# 等畫面穩定: 有 anim 的圖直接 flush 到終點; 沒有的 ( 還在用 d3 transition ) 只能等.
# render 可能是 debounce / ResizeObserver 觸發的, 所以 flush 後要再看 markup 有沒有變
# 等到 DOM 連續 quiet ms 沒有變動才算穩定 ( 預設 250, 要比圖裡的 debounce 長 - 例如 bar 的 brush
# 150ms 後才發 filter, board 再重畫 ). 期間每一幀都 flush, 有 anim 的圖補間會直接跳到終點.
# list 是回傳目前所有圖的 function ( dash 的 panel 圖是非同步建立的, 每次都重抓 ),
# 新抓到的圖一律切 manual. 沒有 anim 的圖 ( 還在用 d3 transition ) 只能靠 quiet 等它跑完
settle = (root, list, quiet = 250, limit = 10000) ->
  new Promise (res) ->
    last = performance.now!
    t0 = last
    mo = new MutationObserver -> last := performance.now!
    mo.observe root, {subtree: true, childList: true, attributes: true, characterData: true}
    tick = ->
      charts = list!filter -> it
      charts.map ->
        if !it.anim => return
        if !it.anim._manual => it.anim.manual true
        it.anim.flush!
      now = performance.now!
      if now - last >= quiet or now - t0 > limit =>
        mo.disconnect!
        return res!
      requestAnimationFrame tick
    requestAnimationFrame tick

# ---------------------------------------------------------------- suite

mctest.suite = (s = {}) ->
  s.size = s.size or [480, 320]
  mctest.suites.push s
  (s.cases or []).map (c) ->
    mctest.cases.push ({} <<< c <<< {suite: s, file: mctest.file(c.name)})
  s

get-data = (s, d) ->
  if !d => d = Object.keys(s.data or {}).0
  if typeof(d) == \string =>
    if !(s.data and s.data[d]) => throw new Error("[mctest] unknown data `#d`")
    d = s.data[d]
  if typeof(d) == \function => d = d!
  JSON.parse JSON.stringify d

chart-ref = (s) -> ({version: \main} <<< (s.chart or {name: mctest.info.name}))

make-chart = (s, root) ->
  mgr.get chart-ref(s)
    .then (bc) -> bc.create {data: {}}
    .then (bi) -> bi.attach {root} .then -> bi.interface!
    .then (chart) ->
      if chart.anim => chart.anim.manual true
      chart

load-dash = ->
  if mctest._dash => return mctest._dash
  base = "/assets/lib/@plotdb/dash/main/web/static"
  mctest._dash = new Promise (res, rej) ->
    css = document.createElement \link
    css <<< {rel: \stylesheet, href: "#base/css/dash.css"}
    document.head.appendChild css
    js = document.createElement \script
    js.src = "#base/js/dash.js"
    js.onload = -> res window.dash
    js.onerror = -> rej new Error("[mctest] @plotdb/dash not found - link it with `-l @plotdb/dash:<dir>`")
    document.head.appendChild js

# 跑一個 case. root 是給它用的容器 ( 大小由這裡設 ). 回傳 {snaps, chart | board}
mctest.run-case = (c, root) ->
  s = c.suite
  [w, h] = c.size or (c.dash and c.dash.size) or s.size
  root.style <<< {width: "#{w}px", height: "#{h}px"}
  snaps = []
  charts = []
  list = -> charts
  q = c.quiet ? s.quiet
  ctx =
    root: root
    snap: (label) ->
      settle(root, list, q).then -> snaps.push {label: (label or "step#{snaps.length}"), markup: normalize(root, s.normalize)}
    drag: mctest.drag
    wait: wait
    random: mctest.random
  run-steps = (target) ->
    # 先等第一次畫完, step 才找得到節點
    (c.steps or []).reduce ((p, f) -> p.then(-> f target, ctx).then -> settle(root, list, q)), settle(root, list, q)
      .then -> snaps.push {label: \final, markup: normalize(root, s.normalize)}
      .then -> {snaps, target}
  if c.dash => return load-dash!then (dash) ->
    board = new dash.board do
      root: root
      manager: mgr
      def: JSON.parse(JSON.stringify(c.dash.def))
      panel: {name: "@plotdb/dash", version: \main, path: "web/static/initiative/1st/block/panel/0.0.1/index.html"}
    ctx.chart = (id) -> ((board.panels.filter(-> it.id == id).0 or {}).itf or {}).chart
    list := -> board.panels.map -> (it.itf or {}).chart
    board.init!then -> settle root, list, q
    .then -> run-steps board
  make-chart s, root
    .then (chart) ->
      charts.push chart
      cfg = merge {}, (s.config or {}), (c.config or {})
      chart.config cfg
      d = get-data s, c.data
      chart.set-raw d.raw, d.binding
      if d.subset => chart.subset.set d.subset
      run-steps chart

# 跟 snapshot 比對. 回傳 {status, current, baseline, line, expect, actual, delta}
#  - pass  完全相同
#  - near  結構相同, 數字差都在 tolerance 內 ( 預設 1 ). 不同 DPR / 瀏覽器版本的文字寬度會有小數誤差,
#          html 版面換算到 svg 的位置取整後就會差 1px - 這種不算壞掉, 但會標出來
#  - diff  其他. line / expect / actual 是第一個不同的行
#  - new   還沒有 snapshot
num = /-?\d+(?:\.\d+)?/g
near-line = (a, b, tol) ->
  if a.replace(num, \#) != b.replace(num, \#) => return null
  [na, nb] = [(a.match(num) or []), (b.match(num) or [])]
  d = 0
  for v, i in na => d >?= Math.abs(+v - +nb[i])
  if d <= tol => d else null

mctest.compare = (c, snaps) ->
  current = mctest.join-snaps snaps
  tol = c.tolerance ? c.suite.tolerance ? 1
  fetch "/api/snapshot/#{c.file}"
    .then (r) -> if r.status == 204 => null else r.text!
    .then (baseline) ->
      if !(baseline?) => return {status: \new, current}
      if baseline.trim! == current.trim! => return {status: \pass, current, baseline}
      a = baseline.trim!split \\n
      b = current.trim!split \\n
      first = null
      delta = 0
      for i from 0 til Math.max(a.length, b.length) =>
        if a[i] == b[i] => continue
        if !(first?) => first = i
        d = if a[i]? and b[i]? => near-line(a[i], b[i], tol) else null
        if !(d?) => return {status: \diff, current, baseline, line: i + 1, expect: a[i], actual: b[i]}
        delta >?= d
      {status: \near, current, baseline, delta, line: first + 1, expect: a[first], actual: b[first]}

# 存 snapshot 一律交給 server 用 headless 重跑 ( 見 lib/runner.js ), 不存 UI 所在瀏覽器畫的版本
mctest.accept = (names) ->
  fetch \/api/accept, {method: \POST, headers: {"Content-Type": "application/json"}, body: JSON.stringify({names})}
    .then (r) -> if r.ok => r.json! else r.text!then -> throw new Error(it)

mctest.match = (c, grep, names) ->
  if names => return c.name in names
  if !grep or c.name.indexOf(grep) >= 0 => return true
  try
    new RegExp(grep).test c.name
  catch e
    false

mctest.boot = ->
  mgr.init!
    .then -> fetch \/api/info
    .then (r) -> r.json!
    .then (info) -> mctest.info = info
    .then ->
      new Promise (res, rej) ->
        s = document.createElement \script
        s <<< {src: \/test/index.js, onload: res, onerror: -> rej new Error("[mctest] load test/index.js failed")}
        document.head.appendChild s

window.mctest = mctest
