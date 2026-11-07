# Change Logs

## v0.0.3

 - ignore empty `style=""` attributes when serializing and comparing: whether one is left depends on
   how a style was set before ( e.g. `style.x = ''` ), not on what is drawn. existing baselines that
   still contain it compare equal without updating


## v0.0.2

 - add playground ( `/playground` in `mctest serve` ): apply any test case's data / config / size,
   replay its steps in real time, swap data from `mod.sample` or suite data, edit raw as CSV and
   binding as JSON, and tweak config from a panel generated from `mod.config`
 - modules not found locally are fetched from npm CDN ( jsdelivr ) and cached in `~/.cache/mctest`.
   add `--offline` to disable it
 - add `ctx.capture(label)`: save the current markup without waiting or flushing, for animation
   frames driven by `chart.anim.step`. `steps` / `cases` accept a single item without an array
 - drag helper sends both pointer and mouse events with integer coordinates ( d3-brush listens to mouse )
 - normalize csscope scope tokens, hex colors as `rgb()` and transform spacing, so d3 / lite
   variants of the same chart compare equal

## v0.0.1

 - init release
 - `mctest` cli: run test cases of a makechart chart in a headless browser and compare the output with
   snapshots in `test/snapshot` ( `-u` to update, `-g` to filter, `--ci`, `--loose`, `--dpr` )
 - `mctest serve`: UI showing current and baseline side by side; accept re-runs the case headlessly
   so snapshots always come from the same environment
 - resolve frontend dependencies at runtime under `/assets/lib/<name>/<ver>/<path>`, with local
   overrides via `-l name:dir` ( same syntax as `fedep -l` ) or `MCTEST_LINK`
 - test case API ( `mctest.suite` ): data sets, per-case config, steps with intermediate snaps,
   pointer drag helper, `combo` / `label` / seeded `random` helpers
 - crossfilter cases via `@plotdb/dash` boards
 - deterministic output: `chart.anim` is switched to manual and flushed, capture waits for a quiet DOM,
   markup is serialized with sorted attributes and rounded numbers, volatile ids are normalized
