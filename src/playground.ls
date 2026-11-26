# mctest playground: 拿一張圖來玩. `mctest serve` 之後開 /playground
#
#  - 資料與設定的起點直接取自 chart 的 test case ( test/index.ls ) 與 mod.sample, 不必另外準備
#  - 選一個 case 就套用它的資料、config 與大小; 有 steps 的可以按「跑 steps」看動畫
#  - 設定面板依 mod.config 自動產生 ( number / boolean / choice / color / format / text ),
#    font ( 字型名稱 ) / quantity ( 數字 + 單位 ), palette 給幾組現成的. 預設把圖放大到填滿可用空間
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

# 說明文字: desc 可以是字串或 {en, zh-TW}, 依瀏覽器語系挑
lang = if /^zh/i.exec(navigator.language or '') => \zh-TW else \en
desc-of = (d) ->
  if !d => '' else if typeof(d) == \string => d else (d[lang] or d.en or d[Object.keys(d).0] or '')
# key 轉成好讀的名字: minRadius / min-radius -> min radius
title-of = (def, k) -> def.name or "#k".replace(/([a-z])([A-Z])/g, '$1 $2').replace(/[-_]/g, ' ').toLowerCase!

control = (def, path) ->
  v = get-at pg.chart.config!, path
  frag = document.createDocumentFragment!
  row = frag.appendChild el(\div, {class: \row})
  d = desc-of def.desc
  lb = row.appendChild el(\label, {title: path.join(\.) + (if d => "\n#d" else '')}, title-of(def, path[* - 1]))
  if d => lb.classList.add \has-desc
  c = row.appendChild el(\div, {class: \ctrl})
  set = (v) -> pg.set path, v
  switch def.type
  | \number =>
    [min, max, step] = [(def.min ? 0), (def.max ? Math.max(100, (v or 0) * 2)), (def.step ? 1)]
    n = c.appendChild el(\input, {type: \range, min, max, step})
    o = c.appendChild el(\input, {type: \number, class: \num, step})
    n.value = o.value = v ? min
    n.oninput = -> o.value = n.value; set +n.value
    o.onchange = -> if o.value != '' and !isNaN(+o.value) => n.value = o.value; set +o.value
  | \boolean =>
    n = c.appendChild el(\input, {type: \checkbox, class: \switch})
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
    n = c.appendChild el(\input, {type: \color, class: \swatch})
    hex = c.appendChild el(\span, {class: \hex}, v or '')
    if /^#[0-9a-f]{6}$/i.exec(v or '') => n.value = v else n.classList.add \unset
    n.oninput = -> n.classList.remove \unset; hex.textContent = n.value; set n.value
    b = c.appendChild el(\button, {}, \預設)
    b.onclick = -> hex.textContent = def.default or ''; set def.default
  | \format, \text, \font =>
    n = c.appendChild el(\input, {type: \text, placeholder: (if def.type == \font => 'font name' else '')})
    n.value = if v and typeof(v) == \object => (v.name or '') else (v ? '')
    n.onchange = -> set(if def.type == \font and !n.value => null else n.value)
  # quantity: 數字 + 單位, 例如 1em / 16px
  | \quantity =>
    units = (def.units or []).map (u) -> if typeof(u) == \string => {name: u} else u
    m = /^\s*(-?[\d.]+)\s*(.*)$/.exec("#{v ? def.default ? ''}") or [null, '', (units.0 or {}).name or '']
    n = c.appendChild el(\input, {type: \number, step: \any})
    n.value = m.1
    u = c.appendChild el(\select, {class: \unit})
    units.map -> u.appendChild el(\option, {value: it.name}, it.name)
    u.value = m.2
    upd = -> if n.value != '' => set "#{n.value}#{u.value}"
    n.onchange = upd
    u.onchange = ->
      d = units.filter(-> it.name == u.value).0
      if d and d.default? => n.value = d.default
      upd!
  | otherwise => return null
  if d => frag.appendChild el(\div, {class: \idesc}, d)
  frag

# 最上層的每個段落一張可收合的卡片 ( 最上層的設定項放在 general ), 裡面的子段落用小標題分開.
# 段落說明取自 mod.tabinfo. 開合狀態記在 pg.open, 換 case / 回預設重畫面板時保留
pg.open = new Set ['']
tab-desc = (path) -> desc-of ((pg.chart.mod.tabinfo or {})[if path.length => path.join(\/) else \common] or {}).desc
# 一個群組的內容: 直接的設定項, 再來是子群組 ( 小標題 + 遞迴 ). 回傳設定項總數
fill-group = (o, path, box, depth) ->
  cnt = 0
  subs = []
  for k, v of o =>
    p = path ++ [k]
    if is-leaf v => (if (r = control v, p) => box.appendChild r; cnt++)
    else if v and typeof(v) == \object and (depth or path.length) => subs.push [v, p]
  for [v, p] in subs =>
    h = el \div, {class: \sub}
    h.appendChild el(\span, {}, p.slice(1).join(' / '))
    if (d = tab-desc p) => h.appendChild el(\div, {class: \gdesc}, d)
    body = el \div
    if (n = fill-group v, p, body, depth + 1) => box.appendChild h; box.appendChild body; cnt += n
  cnt
card = (root, o, path) ->
  key = path.join \/
  g = el \details, {class: \grp}
  if pg.open.has key => g.open = true
  g.ontoggle = -> if g.open => pg.open.add key else pg.open.delete key
  s = g.appendChild el(\summary)
  s.appendChild el(\span, {class: \t}, if path.length => key else \general)
  n = s.appendChild el(\span, {class: \n})
  if (d = tab-desc path) => g.appendChild el(\div, {class: \gdesc}, d)
  if !(n.textContent = fill-group o, path, g, 0) => return
  root.appendChild g
build-panel = (o, root) ->
  card root, o, []
  for k, v of o => if v and typeof(v) == \object and !is-leaf(v) => card root, v, [k]

render-panel = ->
  root = $ \#cfg
  root.textContent = ''
  # palette: 一排色條
  cur = ((pg.chart.config! or {}).palette or {}).key or "預設"
  pals = root.appendChild el(\div, {class: \pals})
  for let k, cs of palettes
    b = pals.appendChild el(\div, {class: "pal#{if k == cur => ' on' else ''}", title: k})
    strip = b.appendChild el(\div, {class: \strip})
    (cs or []).map (c) -> strip.appendChild(el \i).style.background = c
    b.appendChild el(\span, {}, k)
    b.onclick = ->
      Array.from(pals.childNodes).map -> it.classList.toggle \on, it == b
      pg.set [\palette], (if cs => {key: k, colors: cs} else null)
  build-panel pg.chart.mod.config, root

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

# 填滿 ( 預設 ) 時圖跟著可用空間; 關掉才用 case 的大小, 可以拖右下角改
set-size = ([w, h]) ->
  pg.size = [w, h]
  $(\#stage).style <<< {width: "#{w}px", height: "#{h}px"}

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

# 圖的 block data ( 例如地圖的 level ): case 與 suite 有給就用 ( case 的優先, 同 suite.ls ), 否則用網址的 ?block=
url-block = ->
  try JSON.parse((new URLSearchParams(location.search)).get(\block) or '{}')
  catch e
    console.warn "[mctest] bad ?block=", e
    {}
case-block = (c) ->
  if !(c.suite.block or c.block) => return url-block!
  {} <<< (c.suite.block or {}) <<< (c.block or {})

# 建圖. block 不同就重建 ( block data 只在 create 時給得進去 )
make-chart = (block = {}) ->
  key = JSON.stringify block
  if pg.chart and pg.block == key => return Promise.resolve pg.chart
  mctest.manager.get {name: mctest.info.name, version: \main}
    .then (bc) -> bc.create {data: block}
    .then (bi) ->
      if pg.chart and pg.chart.destroy => try pg.chart.destroy! catch e => console.warn "[mctest] destroy:", e
      $(\#stage).textContent = ''
      bi.attach({root: $(\#stage)}).then -> bi.interface!
    .then (chart) ->
      pg.chart = window.chart = chart
      pg.block = key
      $(\#block).textContent = if key == '{}' => '' else "block #key"
      chart

pg.apply-case = (c) ->
  pg.case = c
  make-chart case-block(c)
    .then ->
      $(\#err).textContent = ''
      set-size (c.size or c.suite.size)
      pg.reset-config mctest.merge({}, clone(c.suite.config or {}), clone(c.config or {}))
      if (d = case-data c) => pg.set-data d
      $(\#steps).disabled = !c.steps
    .catch (e) -> $(\#err).textContent = String(e.stack or e)

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
  .then ->
    cases = mctest.cases.filter -> !it.dash and !it.skip
    # 起點的圖: 第一個 case 的 block, 沒有 case 就用網址的 ?block=<json> ( 例如 ?block={"level":"town"} )
    make-chart(if cases.length => case-block(cases.0) else url-block!)
  .then (chart) ->
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
    $(\#fit).onchange = ->
      $(\main).classList.toggle \fit, $(\#fit).checked
      if !$(\#fit).checked and pg.size => set-size pg.size
    $(\#show-desc).onchange = -> document.body.classList.toggle \no-desc, !$(\#show-desc).checked
    new ResizeObserver(->
      b = $(\#stage).getBoundingClientRect!
      fit = $(\#fit).checked
      $(\#size).textContent = "#{Math.round b.width} × #{Math.round b.height}" + (if fit => '' else ' · 拖右下角改大小')
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
