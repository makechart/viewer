# Change Logs

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
