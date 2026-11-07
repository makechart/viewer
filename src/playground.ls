# mctest playground: 拿一張圖來玩. `mctest serve` 之後開 /playground
#
#  - 資料與設定的起點直接取自 chart 的 test case ( test/index.ls ) 與 mod.sample, 不必另外準備
#  - 選一個 case 就套用它的資料、config 與大小; 有 steps 的可以按「跑 steps」看動畫
#  - 設定面板依 mod.config 自動產生 ( number / boolean / choice / color / format / text ),
#    font / palette / quantity 沒有元件, palette 給幾組現成的
#  - 資料用 CSV 編輯 ( raw ), binding 用 JSON. 動畫是真實時間, 不切 manual

$ = (s) -> document.querySelector s
el = (tag, attr = {}, txt) ->
  n = document.createElement tag
  for k, v of attr => n.setAttribute k, v
  if txt? => n.textContent = txt
  n
clone = (o) -> if o? => JSON.parse(JSON.stringify o) else o
wait = (ms) -> new Promise (res) -> setTimeout res, ms

pg = mctest.playground = {}

# ---------------------------------------------------------------- csv
# 只處理常見情形: 逗號分隔, 雙引號包住的欄位可以含逗號 / 換行 / "" 跳脫
csv =
  parse: (s) ->
    [rows, row, cur, q, i] = [[], [], '', false, 0]
    while i < s.length
      c = s[i]
      if q =>
        if c == '"' and s[i + 1] == '"' => cur += '"'; i++
        else if c == '"' => q = false
        else cur += c
      else if c == '"' => q = true
      else if c == ',' => row.push cur; cur = ''
      else if c == '\n' or c == '\r' =>
        if c == '\r' and s[i + 1] == '\n' => i++
        row.push cur
        rows.push row
        [row, cur] = [[], '']
      else cur += c
      i++
    if cur or row.length => row.push cur; rows.push row
    rows.filter -> it.some (v) -> v.trim! != ''
  cell: (v) ->
    v = if v? => "#v" else ''
    if /[",\n\r]/.exec(v) => "\"#{v.replace(/"/g, '""')}\"" else v
  # rows ( 物件陣列 ) -> csv. 欄位取所有列的聯集, 依第一次出現的順序
  from: (raw = []) ->
    keys = []
    raw.map (r) -> for k of r => if !(k in keys) => keys.push k
    if !keys.length => return ''
    ([keys] ++ raw.map((r) -> keys.map (k) -> r[k])).map((r) -> r.map(csv.cell).join \,).join \\n
  # csv -> rows. 看起來是數字的轉成數字, 空格留空字串
  to: (s) ->
    rows = csv.parse s
    if !rows.length => return []
    [head, ...body] = rows
    body.map (r) ->
      Object.fromEntries head.map (h, i) ->
        v = (r[i] or '').trim!
        [h.trim!, (if v != '' and !isNaN(+v) => +v else v)]

# ---------------------------------------------------------------- config panel
is-leaf = (o) -> o and typeof(o) == \object and typeof(o.type) == \string
defaults = (o) ->
  ret = {}
  for k, v of o =>
    if is-leaf v => (if v.default? => ret[k] = clone v.default)
    else if v and typeof(v) == \object => ret[k] = defaults v
  ret
get-at = (o, path) -> path.reduce ((a, k) -> (a or {})[k]), o
patch-of = (path, v) ->
  ret = p = {}
  for k in path.slice(0, -1) => p = p[k] = {}
  p[path[* - 1]] = v
  ret

palettes =
  "預設": null
  tableau: <[#4e79a7 #f28e2b #e15759 #76b7b2 #59a14f #edc948 #b07aa1 #ff9da7 #9c755f #bab0ac]>
  "冷色": <[#264653 #2a9d8f #8ab17d #457b9d #1d3557 #a8dadc]>
  "暖色": <[#9b2226 #ae2012 #bb3e03 #ca6702 #ee9b00 #e9d8a6]>

control = (def, path) ->
  v = get-at pg.chart.config!, path
  row = el \div, {class: \row}
  row.appendChild el(\label, {title: path.join(\.)}, path[* - 1])
  c = row.appendChild el(\div, {class: \ctrl})
  set = (v) -> pg.set path, v
  switch def.type
  | \number =>
    [min, max, step] = [(def.min ? 0), (def.max ? Math.max(100, (v or 0) * 2)), (def.step ? 1)]
    n = c.appendChild el(\input, {type: \range, min, max, step})
    o = c.appendChild el(\span, {class: \v})
    n.value = v ? min
    o.textContent = n.value
    n.oninput = -> o.textContent = n.value; set +n.value
  | \boolean =>
    n = c.appendChild el(\input, {type: \checkbox})
    n.checked = !!v
    n.onchange = -> set n.checked
  | \choice =>
    n = c.appendChild el(\select)
    (def.values or []).map (o) ->
      [val, name] = if o and typeof(o) == \object => [o.value, o.name] else [o, o]
      n.appendChild el(\option, {value: JSON.stringify(val)}, name)
    n.value = JSON.stringify v
    n.onchange = -> set JSON.parse(n.value)
  | \color =>
    n = c.appendChild el(\input, {type: \color})
    if /^#[0-9a-f]{6}$/i.exec(v or '') => n.value = v
    n.oninput = -> set n.value
    b = c.appendChild el(\button, {}, \預設)
    b.onclick = -> set def.default
  | \format, \text =>
    n = c.appendChild el(\input, {type: \text})
    n.value = v ? ''
    n.onchange = -> set n.value
  | otherwise => return null
  row

# 群組攤平成一層 ( legend 寫完整路徑 ), 只有子群組、沒有直接設定項的群組不出現
build-panel = (o, path, root, fs) ->
  subs = []
  for k, v of o =>
    p = path ++ [k]
    if is-leaf v => (if fs and (r = control v, p) => fs.appendChild r)
    else if v and typeof(v) == \object => subs.push [v, p]
  if fs and fs.querySelector(\.row) => root.appendChild fs
  for [v, p] in subs =>
    g = el \fieldset
    g.appendChild el(\legend, {}, p.join \.)
    build-panel v, p, root, g

render-panel = ->
  root = $ \#cfg
  root.textContent = ''
  row = root.appendChild el(\div, {class: \row})
  row.appendChild el(\label, {}, \palette)
  sel = row.appendChild(el \div, {class: \ctrl}).appendChild el(\select)
  for k of palettes => sel.appendChild el(\option, {value: k}, k)
  sel.onchange = ->
    p = palettes[sel.value]
    pg.set [\palette], (if p => {key: sel.value, colors: p} else null)
  # 最上層的設定項放在沒有 legend 的那一組
  build-panel pg.chart.mod.config, [], root, el(\fieldset)

# ---------------------------------------------------------------- chart
redraw = ->
  c = pg.chart
  c.parse!; c.bind!; c.resize!; c.render!

pg.set = (path, v) ->
  pg.chart.config patch-of(path, v)
  redraw!

# 設定整個換掉: 回到預設再套 cfg
pg.reset-config = (cfg = {}) ->
  c = pg.chart
  c.cfg = {}
  c.config (mctest.merge defaults(c.mod.config), clone(cfg))
  redraw!
  render-panel!

pg.set-data = (d) ->
  $(\#err).textContent = ''
  pg.data = d = clone d
  $(\#csv).value = csv.from d.raw
  $(\#binding).value = JSON.stringify(d.binding or {}, null, 2)
  pg.chart.set-raw (if d.subset? => d else {raw: d.raw, binding: d.binding, subset: null})

apply-editor = ->
  $(\#err).textContent = ''
  try
    pg.data = {raw: csv.to($(\#csv).value), binding: JSON.parse($(\#binding).value or '{}')}
    pg.chart.set-raw {raw: pg.data.raw, binding: pg.data.binding, subset: null}
  catch e => $(\#err).textContent = String(e.message or e)

set-size = ([w, h]) -> $(\#stage).style <<< {width: "#{w}px", height: "#{h}px"}

# 資料來源: mod.sample, 各 suite 的 data. case: 不含 dash 的 test case
sources = ->
  ret = []
  if pg.chart.mod.sample => ret.push {name: "sample ( mod.sample )", get: -> pg.chart.mod.sample!}
  for s in mctest.suites => for k, v of (s.data or {}) => let v
    ret.push {name: "data: #k", get: -> clone(if typeof(v) == \function => v! else v)}
  ret

case-data = (c) ->
  s = c.suite
  d = c.data or Object.keys(s.data or {}).0
  if typeof(d) == \string => d = (s.data or {})[d]
  if typeof(d) == \function => d = d!
  clone d

pg.apply-case = (c) ->
  set-size (c.size or c.suite.size)
  pg.reset-config mctest.merge({}, clone(c.suite.config or {}), clone(c.config or {}))
  if (d = case-data c) => pg.set-data d
  $(\#steps).disabled = !c.steps
  pg.case = c

# steps 拿到的 ctx 是簡化過的: snap 只是停一下讓人看得到那一格
pg.run-steps = ->
  if !(c = pg.case and pg.case.steps) => return
  c = [].concat c
  ctx =
    root: $(\#stage), wait: wait, random: mctest.random, drag: mctest.drag
    snap: -> wait 800
    capture: -> Promise.resolve!
  c.reduce ((p, f) -> p.then(-> f pg.chart, ctx).then(-> wait 600)), Promise.resolve!
    .catch (e) -> $(\#err).textContent = String(e.stack or e)

mctest.boot!
  .then ->
    $(\#target).textContent = "#{mctest.info.name}@#{mctest.info.version}"
    document.title = "playground · #{mctest.info.name}"
    mctest.manager.get {name: mctest.info.name, version: \main}
  .then (bc) -> bc.create {data: {}}
  .then (bi) -> bi.attach({root: $(\#stage)}).then -> bi.interface!
  .then (chart) ->
    pg.chart = window.chart = chart
    # case 選單
    sel = $ \#case
    cases = mctest.cases.filter -> !it.dash and !it.skip
    sel.appendChild el(\option, {value: ''}, "-- 選一個 case ( #{cases.length} ) --")
    cases.map (c, i) -> sel.appendChild el(\option, {value: i}, c.name + (if c.steps => ' ▶' else ''))
    sel.onchange = -> if sel.value != '' => pg.apply-case cases[+sel.value]
    # 資料選單
    src = $ \#source
    list = sources!
    src.appendChild el(\option, {value: ''}, "-- 換資料 ( 保留設定 ) --")
    list.map (s, i) -> src.appendChild el(\option, {value: i}, s.name)
    src.onchange = ->
      if src.value == '' => return
      try pg.set-data list[+src.value].get! catch e => $(\#err).textContent = String(e.stack or e)
      src.value = ''
    $(\#apply).onclick = apply-editor
    $(\#steps).onclick = pg.run-steps
    $(\#reset).onclick = -> pg.reset-config!
    $(\#dump).onclick = ->
      cfg = pg.chart.config!
      console.log cfg
      $(\#out).textContent = JSON.stringify cfg, null, 2
    $(\#rerender).onclick = redraw
    new ResizeObserver(->
      b = $(\#stage).getBoundingClientRect!
      $(\#size).textContent = "#{Math.round b.width} × #{Math.round b.height} · 拖右下角改大小"
    ).observe $(\#stage)
    # 起點: 第一個 case, 沒有就用 sample
    if cases.length => sel.value = 0; pg.apply-case cases.0
    else
      set-size [640, 400]
      pg.reset-config!
      if list.length => pg.set-data list.0.get!
  .catch (e) ->
    $(\#err).textContent = String(e.stack or e)
    console.error e
