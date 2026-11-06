# @makechart/viewer

makechart 圖表的 test suite engine。每張圖在自己的 repo 放 test case，engine 用 headless 瀏覽器以各種資料、參數跑過，把輸出跟存下來的 snapshot 比對；也能用 `@plotdb/dash` 把幾張圖串起來測 crossfilter。


## 安裝

在 chart repo 裡：

    npm install -D @makechart/viewer

本地開發 engine 時可以改用 `npm link` 或 `npm install -D <path-to-viewer>`。

需要一個 headless 瀏覽器：預設用 playwright 的 chromium ( `npx playwright install chromium-headless-shell` )，沒裝就用系統的 Chrome。


## 使用

在 chart repo 的根目錄：

    npx mctest                 # 跑全部 case. 沒有 snapshot 的會直接存起來
    npx mctest -u              # 不一致的也更新 snapshot
    npx mctest -g stack        # 只跑名字含 stack 的 ( 也可以是 regexp )
    npx mctest --ci            # 沒有 snapshot 也算失敗
    npx mctest serve -o        # 開 UI: 並排看 current / baseline, accept

`npx mctest -h` 看全部選項。結束碼不是 0 代表有 case 失敗，失敗的 markup 與截圖放在 `test/output/`。


## 依賴從哪裡來

engine 自己起一個 server，前端依賴走與 makechart 相同的路徑 `/assets/lib/<name>/<version>/<path>`，版本一律忽略，依序找：

 1. `-l name:dir` ( 或環境變數 `MCTEST_LINK` ) 指定的本地目錄，有 `dist/` 先找 `dist/`
 2. 受測的圖自己 ( package.json 的 name -> `./dist` )
 3. `node_modules`，先 chart repo 再 engine 自己的 ( npm link 的 symlink 一樣適用 )

所以本地開發不必每張圖都 clone，要改的那幾個連過去就好：

    npx mctest -l "@makechart/base:../base;@plotdb/chart:~/workspace/plotdb/projects/chart"

`-l` 的寫法同 `fedep -l`。`@plotdb/dash` 目前沒有發佈，dash 的 case 要把它連過來，沒連的話這些 case 會是 error。


## 寫 test case

`test/index.ls` ( 或 `test/index.js` )，在瀏覽器裡執行，可以用全域的 `mctest`：

    mctest.suite do
      size: [480 300]                  # 預設的圖大小 ( px )
      config: {}                       # 所有 case 共用的 config
      data:
        fruit: {raw: [...], binding: {...}}    # 也可以是回傳 {raw, binding, subset?} 的 function
      cases:
        * name: "stack", data: \fruit, config: {multiple: \stack}
        * name: "filter"
          steps:
            * (chart, ctx) ->
                chart.filter {name: {type: \index, value: <[A B]>}}
                ctx.snap \filtered     # 在這裡多存一格
            * (chart) -> chart.filter {name: undefined}
        * name: "dash"                 # 多張圖, 用 @plotdb/dash 的 board
          dash: {def: {...}, size: [900 320]}
          steps: [(board, ctx) -> board.set-filter \a, {field: \region, values: <[North]>}]

 - `name` 是 snapshot 的檔名，要唯一。
 - `steps` 依序執行，每一步之後等畫面穩定。可以回傳 promise。
 - `ctx`：`root` ( 這個 case 的容器 )、`snap(label)`、`drag(node, [x0, y0], [x1, y1])` ( 相對座標 0~1，送 pointer 事件 )、`chart(id)` ( dash 時取某個 panel 的圖 )、`wait(ms)`、`random(seed)`。
 - helper：`mctest.combo {type: <[column bar]>, multiple: <[stack group]>}` 產生所有組合，`mctest.label o` 把組合轉成名字，`mctest.random seed` 是固定種子的亂數。
 - `skip: true` 略過。`suite.chart` 預設是 package.json 的 name。

資料請用固定種子產生，否則每次跑都不一樣。


## 怎麼比對

 - 動畫：有 `chart.anim` 的圖 ( @plotdb/chart 的補間時鐘 ) 一律切成 manual，再直接 flush 到終點，所以結果跟機器快慢無關。還在用 d3 transition 的圖只能等它跑完。
 - 穩定：DOM 連續 `quiet` ms ( 預設 250 ) 沒有變動才擷取，要比圖裡的 debounce 長。
 - markup：自己序列化 DOM，屬性依名字排序，一個 tag 一行，數字取到小數兩位，並把每次都會變的亂數 id 換掉 ( ldview scope、legend id；圖表自己的用 `suite.normalize: [[regexp, 取代字串]]` 補 )。
 - 每個 case 都在固定於頁面 (0, 0) 的位置執行，版面不受前面的 case 影響。
 - 結果：`pass` 完全相同；`near` 結構相同、只差數字，而且差距在 `tolerance` 內 ( 預設 1 )；`diff`；`new` 沒有 snapshot。cli 預設把 `near` 也算失敗，加 `--loose` 才放過。`near` 多半出現在 UI：你的瀏覽器跟 headless 的 DPR、視窗不同，文字寬度會有小數誤差。

snapshot 一律由 headless 產生 ( viewport 1600x1000，DPR 預設 2，`--dpr` 可改 )。UI 的 accept 也是請 server 用 headless 重跑那幾個 case 再存，不會存 UI 所在瀏覽器畫出來的版本。

文字寬度跟字型、瀏覽器版本有關，不同機器 ( 例如 CI 的 linux ) 需要各自的 baseline，或固定瀏覽器與字型。


## 檔案

 - `bin/cli.js` — 指令
 - `lib/server.js` — http server：依賴解析、test case 編譯、snapshot API
 - `lib/runner.js` — headless 瀏覽器 ( playwright-core )
 - `src/suite.ls` — 瀏覽器端 engine：case 定義、執行、正規化、比對
 - `src/ui.ls`、`web/index.html` — UI ( headless 也是跑這頁 )
