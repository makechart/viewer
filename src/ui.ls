# mctest UI: 列出所有 case, 跑完跟 snapshot 比對.
#  - 一般開啟: 每個 case 並排顯示 current ( 目前的程式畫的, 最後一格是活的, 可以操作 ) 與 baseline
#    ( 存下來的 markup 直接塞回頁面, chart 的 css 已經載入, 所以看起來就是當時的樣子 ). 可以 accept
#  - ?headless: 不自動跑, 由 cli 呼叫 mctest.ui.run 拿結果 ( cli 自己寫檔、截圖 )

$ = (s) -> document.querySelector s
el = (tag, cls, txt) ->
  n = document.createElement tag
  if cls => n.className = cls
  if txt? => n.textContent = txt
  n

ui = mctest.ui = {results: {}}
params = new URLSearchParams(location.search)
headless = params.has \headless

frame-of = (c, markup) ->
  [w, h] = c.size or (c.dash and c.dash.size) or c.suite.size
  f = el \div, \frame
  f.style <<< {width: "#{w}px", height: "#{h}px"}
  if markup? => f.innerHTML = markup
  f

snap-node = (label, node) ->
  s = el \div, \snap
  s.appendChild el(\div, \label, label)
  s.appendChild node
  s

card = (c) ->
  n = el \div, \case
  n.dataset.file = c.file
  head = el \div, \head
  head.appendChild el(\span, \name, c.name)
  head.appendChild (n._badge = el \span, \badge, \running)
  head.appendChild (n._accept = el \button, '', \accept)
  n._accept.style.display = \none
  head.appendChild (n._info = el \span, \info)
  n.appendChild head
  panes = el \div, \panes
  cur = el \div, 'pane current'
  cur.appendChild el(\div, \t, \current)
  cur.appendChild (n._cur = el \div, \snaps)
  base = el \div, 'pane baseline'
  base.appendChild el(\div, \t, \baseline)
  base.appendChild (n._base = el \div, \snaps)
  panes.appendChild cur
  panes.appendChild base
  n.appendChild panes
  n.appendChild (n._diff = el \pre, \diff)
  n

set-status = (n, r) ->
  n.className = "case #{r.status}"
  n._badge.className = "badge #{r.status}"
  n._badge.textContent = r.status
  # near 是這個瀏覽器跟 headless 的誤差, accept 也只會存回一樣的東西
  n._accept.style.display = if r.status in <[diff new]> => '' else \none
  n._diff.textContent = if r.status == \near =>
    "跟 snapshot 只差在數字 ( 最多 #{r.delta} ) - 多半是這個瀏覽器跟 headless 的文字寬度誤差. cli 預設仍算失敗, 以 cli 為準. 第一處在 line #{r.line}\n- #{r.expect}\n+ #{r.actual}"
  else if r.status == \diff =>
    "first diff at line #{r.line}\n- #{r.expect ? '( none )'}\n+ #{r.actual ? '( none )'}"
  else if r.status == \error => r.error
  else ''

# case 一律在固定於 (0, 0) 的 stage 上跑, 跑完才搬進卡片. 圖的版面 ( 例如 legend 從 html 換算到 svg 的位置 )
# 會受頁面上絕對座標的小數部分影響 ( 各自取整 ), 不固定的話前面的卡片高度一變, 後面的數字就差 1px
stage = el \div, \stage
document.body.appendChild stage

run-one = (c, n) ->
  # 最後一格用活的 chart; 中間的 snap 跟 baseline 都是靜態的 markup
  live = frame-of c
  stage.appendChild live
  Promise.resolve!
    .then -> mctest.run-case c, live
    .finally -> n._cur.appendChild snap-node(\final, live)
    .then ({snaps}) ->
      snaps.slice(0, -1).map (s) -> n._cur.insertBefore snap-node(s.label, frame-of(c, s.markup)), n._cur.lastChild
      mctest.compare c, snaps
    .catch (e) -> {status: \error, error: String(e.stack or e)}
    .then (r) ->
      if r.baseline and !headless =>
        mctest.split-snaps(r.baseline).map (s) -> n._base.appendChild snap-node(s.label, frame-of(c, s.markup))
      set-status n, r
      n._accept.onclick = -> ui.accept [c]
      ui.results[c.file] = r <<< {name: c.name, file: c.file}

summary = ->
  cnt = {}
  for k, r of ui.results => cnt[r.status] = (cnt[r.status] or 0) + 1
  $(\#summary).innerHTML = ''
  for k in <[pass near diff new error skip]> => if cnt[k] =>
    $(\#summary).appendChild el(\span, "badge #k", "#k #{cnt[k]}")

# headless 重跑後存檔, 再用新的 snapshot 重新比對畫面上這次的結果 ( 這個瀏覽器可能是 near )
ui.accept = (cs) ->
  if !cs.length => return
  nodes = cs.map (c) -> document.querySelector ".case[data-file=\"#{c.file}\"]"
  nodes.map -> if it => it._badge.textContent = \saving
  mctest.accept cs.map(-> it.name)
    .then -> Promise.all cs.map (c, i) ->
      r = ui.results[c.file]
      n = nodes[i]
      mctest.compare c, mctest.split-snaps(r.current) .then (nr) ->
        n._base.innerHTML = ''
        if nr.baseline => mctest.split-snaps(nr.baseline).map (s) -> n._base.appendChild snap-node(s.label, frame-of(c, s.markup))
        ui.results[c.file] = nr <<< {name: c.name, file: c.file}
        set-status n, nr
    .catch (e) -> nodes.map -> if it => set-status it, {status: \error, error: "accept failed: #{e.message or e}"}
    .then -> summary!

# 依序跑 ( 同時跑會互相搶 rAF / 版面, 數字也比較難重現 )
ui.run = (opt = {}) ->
  root = $(\#cases)
  root.innerHTML = ''
  ui.results = {}
  list = mctest.cases.filter -> mctest.match it, opt.grep, opt.names
  list.reduce ((p, c) ->
    n = card c
    root.appendChild n
    if c.skip =>
      ui.results[c.file] = {name: c.name, file: c.file, status: \skip}
      set-status n, {status: \skip}
      return p
    p.then -> run-one c, n .then -> summary!
  ), Promise.resolve!
    .then -> [v for k, v of ui.results]

mctest.boot!
  .then ->
    $(\#target).textContent = "#{mctest.info.name}@#{mctest.info.version} · #{mctest.cases.length} cases"
    $(\#grep).value = params.get(\grep) or ''
    $(\#run).onclick = ->
      u = new URL(location.href)
      if $(\#grep).value => u.searchParams.set \grep, $(\#grep).value else u.searchParams.delete \grep
      history.replaceState null, '', u.toString!
      ui.run grep: $(\#grep).value
    $(\#grep).onkeydown = (e) -> if e.key == \Enter => $(\#run).click!
    $(\#only-fail).onchange = -> document.body.classList.toggle \only-fail, $(\#only-fail).checked
    $(\#accept-all).onclick = ->
      files = Array.from(document.querySelectorAll '.case.diff, .case.new').map -> it.dataset.file
      ui.accept mctest.cases.filter -> it.file in files
    ui.ready = true
    if !headless => ui.run grep: $(\#grep).value
  .catch (e) ->
    ui.error = String(e.stack or e)
    $(\#cases).textContent = ui.error
