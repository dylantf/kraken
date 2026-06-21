# Design Review — Ordered TODO

Date: 2026-06-21

A prioritized worklist coming out of a design/ergonomics review of the library.
Ordered so we can knock them out one at a time, top to bottom. Each item notes
the problem, the fix, and the relevant code locations.

The review's headline: the core design is strong (nullability-from-schema+join,
`Sql a` as the universal fragment+decoder, deferred `$n` numbering, effects over a
builder monad, full-join-as-its-own-constructor). These items are about closing
the gaps, not reworking the foundation.

---

## 1. Close the soundness lies

The places where the type says one thing and runtime can disagree — highest
priority, because they undercut the whole value proposition of a typed builder.

### 1a. `scalar_subquery` types an empty result as non-null — DONE (2026-06-21)

- **Problem:** `scalar_subquery` returns `Sql a`, but an empty subquery yields SQL
  NULL → decode failure at runtime. Docs say "remember to `coalesce`," but
  "remember or it crashes" is what the types should eliminate.
- **Fix:** add `scalar_subquery_maybe : ... -> Sql (Maybe a)` as the safe default;
  keep the non-null variant for deliberate use (after `limit! 1` on a
  guaranteed-present row, or an aggregate that always returns a row).
- **Where:** `lib/Kraken/Db/Query.saga` (`scalar_subquery` / `scalar_subquery_maybe`,
  sharing a new `scalar_subquery_frag` helper).
- **Done:** added `scalar_subquery_maybe`, factored the shared fragment builder,
  rewrote the `scalar_subquery` doc to mark the non-null soundness boundary. Demo:
  `users_with_a_post_title_query` in `src/Read.saga`. `saga check` green.

### 1b. `insert_all` panics on a runtime-empty list — DONE (2026-06-21)

- **Problem:** an empty batch is *data*, not programmer error (real call sites
  guard `[]`). Panicking on a runtime value — silent until production if the guard
  is forgotten — is the sharpest edge in the library.
- **Fix (chosen):** a `noop: Bool` flag on `Prepared`. `insert_all` /
  `insert_all_returning` return `noop_prepared` for `[]`; `exec` short-circuits to
  `Ok 0`, `all` to `Ok []` (so `one` → `Ok Nothing`, `exactly_one` →
  `ExpectedOneRow 0`), all without a database round trip. No call-site guard needed.
  This keeps the build/execute split clean — the flag is part of the built artifact
  describing what to execute.
- **Where:** `Prepared` + `noop_prepared` + `all` in `lib/Kraken/Db/Query.saga`;
  `exec` + the two `insert_all*` guards in `lib/Kraken/Db/Dml.saga`. The
  `insert_all_parts_of` panic is now an unreachable defensive backstop.
- **Done:** `saga check` green. Not yet exercised against a live DB.

> The other panics (two `from!`, conflict-covers-all-columns, `update_all` on
> `NoKey`) are genuine programmer errors — leave them as panics.

---

## 2. Fix the O(n²) append patterns — DONE (2026-06-21)

Pervasive and cheap to fix now while the surface is small; annoying to retrofit
once large `IN` lists / wide bulk inserts appear.

- **Problem:** rendering snocs onto a growing list per part, and the DML renderer
  does `acc.sql <> text` per part; `QueryState` snocs each clause too.
- **What was actually O(n²) (scales with *data* — big `IN` lists, bulk inserts):**
  - `render_text`/`render_frag` — `List.append state.parts [...]` snoc onto the
    growing accumulator.
  - DML `render_parts` — `acc.sql <> text` per part.
  - `number_parts` — right-recursive `text <> sql` re-copied the growing suffix.
- **What only *looked* it (left as-is):** `append_frag`/`append_frags` in `Db.saga`
  are right-nested with small left operands, and `lists:append(Xs,Ys)` is O(|Xs|),
  so they're linear. The effect-op clause accumulators (`List.append state.wheres
  [expr]`) are O(clauses²) but clauses are hand-written and always tiny — not a
  data-scaling risk. Noted, not changed.
- **Fix (chosen):** accumulate the parts list reversed (O(1) cons) and reverse once
  at extraction (mirrors saga_json's reversed-iolist renderer). `number_parts`
  became a single left fold building reversed text pieces + params, then
  `String.join "" (reverse …)` once — O(n). Made `number_parts` `pub` and routed the
  DML layer through it, deleting DML's duplicated `Rendered`/`render_parts`.
- **Verified:** golden diff of 17 representative rendered queries (selects, joins,
  subqueries, CTE, full join, window, CASE/CONCAT, arithmetic, INSERT) — byte
  identical before/after via a clean worktree at the prior commit.

---

## BUG (discovered during #2 verification) — `insert_all` crashes at runtime

**Pre-existing, not from this review's work.** Surfaced when the golden-diff harness
ran the demo's bulk insert.

- **Symptom:** `saga run` of the demo crashes at the bulk-insert line:
  ```
  Runtime error: bad argument
    read:__dict_Kraken_Db_InsertRow_read_Read_UsersInsert
    kraken_db_dml:insert_pairs/4
    kraken_db_dml:insert_all_parts_of
    write:insert_users_query
  ```
- **Diagnosis:** single-row `Dml.insert` works (calls `insert_pairs` directly), but
  `insert_all_parts_of` calls it through `List.map (fun v -> insert_pairs table_value
  v) values` and the `InsertRow` / `ColumnNameMap` dictionary isn't threaded into the
  mapped closure → undefined `__dict_…` → "bad argument". Looks like a **compiler
  dictionary-passing bug** for a constrained function invoked inside a mapped lambda
  (relevant to the saga compiler repo, not Kraken source).
- **Impact:** `insert_all` / `insert_all_returning` are unusable at runtime for the
  demo's synthesized insert types, despite typechecking and being marked "done".
- **Next:** build a minimal repro (constrained fn called inside `List.map`), fix in
  the compiler, or work around in Kraken by hoisting the dict (e.g. a recursive
  helper that takes the value explicitly rather than a closure over `List.map`).

---

## 3. Ship `DISTINCT` / `DISTINCT ON`

- **Problem:** still listed as near-term Tier 1 and not done; one of the genuinely
  common missing things. `count_distinct` doesn't cover row-level distinct.
- **Fix:** `distinct!` (`SELECT DISTINCT`) and `DISTINCT ON (...)`; thread through
  `QueryState` and render after `SELECT`.

---

## 4. Nested correlated subquery alias collision

- **Problem:** nested correlated subqueries collide on the fixed `s` alias prefix —
  silently produces wrong SQL rather than a type error, violating the
  "no silent footguns" property held everywhere else.
- **Fix:** thread a monotonic alias counter through `QueryState` instead of a fixed
  `t`/`s` prefix. At minimum add a build-time guard if the full fix is deferred.
- **Where:** `lib/Kraken/Db/Query.saga:181` (`empty_state_sub`), alias generation in
  `bind_table_source` / the subquery handlers.

---

## 5. Nested / aggregated relation loading (the big one)

- **Problem:** "load each user with their posts as a nested list" has no path beyond
  N+1 or manual reshaping. This is the main expressivity frontier for building a
  real app — explicitly *not* an ORM, but the composable non-ORM version is missing.
- **Fix:** a `json_agg` / `array_agg`-into-nested-decode helper — aggregate children
  into JSONB in SQL, decode through the existing `Jsonb a` path. Fits the current
  model cleanly; would be a standout feature.
- **Status:** design first, then implement. (Ask Claude to sketch the design.)

---

## 6. Consider collapsing the `_sql` API doubling

- **Problem:** `eq`/`eq_sql`, `add`/`add_sql`, `coalesce`/`coalesce_sql`, etc. roughly
  double the predicate/arithmetic surface; cost compounds as operators are added.
- **Fix to evaluate (not necessarily adopt):** a single `lit`/`val` wrapper at call
  sites (`eq u.age (val other_col)` vs `eq u.age 18`) to collapse each pair. The
  answer may end up "no, the split reads better" — this is a decision to make
  deliberately, not a guaranteed change.
- **Note:** a bare-value `ToSql` instance is ambiguous/overlapping, which is why the
  split exists today.

---

## Minor / opportunistic (fold into nearby work)

- **`select!` is nearly decorative** — `query` uses the closure's return value; a
  stray second `select!` is silently ignored. Reads fine as DSL punctuation; just be
  aware. (`lib/Kraken/Db/Query.saga:294`, `:309`)
- **`LIMIT`/`OFFSET` inlined as `show n`** rather than bound params. Safe (typed
  `Int`) but inconsistent with the param model — add a one-line comment that it's
  deliberate. (`lib/Kraken/Db/Query.saga:585`)
