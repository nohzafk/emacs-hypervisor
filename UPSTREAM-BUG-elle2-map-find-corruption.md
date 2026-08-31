# Elle 2.0 upstream bug: map+find corrupts the mapped list

## Minimal repro (`/tmp/final-min72.lisp`, epoch 10 and 12 both fail identically)

```lisp
(elle/epoch 10)
(defn find-entry [entries name]
  (match entries
    () nil
    (entry & rest)
      (if (= (get entry :name) name) entry (find-entry rest name))
    _ nil))
(def r1 (list {:name "a"} {:name "b"} {:name "c"} {:name "d"}))
(def r2 (map (fn [u] u) r1))
(println "r2= " r2)          ; prints fine: ({:name "a"} ... {:name "d"})
(println "found: " (find-entry r2 "c"))   ; works, prints {:name "c"}
(println "r2-live: " r2)    ; CORRUPTED: ({:name "a"} {:name "b"} <heap:0x...>)
```

## Observation
- The list `r2` produced by `map` gets its tail clobbered after a recursive
  `find-entry`-style function walks it with `match`/`rest`/`first`.
- The **source** list `r1` stays intact; only the **map-produced** list is affected.
- The corruption is deterministic and immediate: after ONE `find-entry r2 "c"`,
  `r2`'s third element prints as `<heap:0x...>` (a dangling/freed Value), and
  `length r2` errors with "Not a proper list".
- Also reproducible with `filter`, `reverse`, and even `(map identity r1)`.
- `get r2 2` returns `nil` after the walk (was `{:name "c"}`).
- Saving the value first (`(def saved (get r2 2))`) survives, so this is the
  cons cell's memory being freed/reused, not the struct payload.
- Occurs at both `(elle/epoch 10)` and `(elle/epoch 12)`.
- `--jit=off` does not change it.

## Bisect
- Introduced by **`10e13314` "region-ownership memory model (elle v2.0.0)"**.
- The old ref `8cf169cd` (elle 1.0) is NOT affected (clean rebuild verified).
- The upstream "fix" commit `e9351a9e` "vm: a parked primitive call's resume
  value arrives counted (#932)" is present at latest but does NOT fix this —
  a clean rebuild at `e9351a9e` still corrupts.

## What it means
- A self-recursive `defn` walking a freshly-`map`ped list, holding the collected
  values, releases/frees cons cells that the caller still owns.
- The elle 2.0 region/inference pass over-approximates or under-counts holds
  on the map-produced structure. This is upstream, not our code.

## Upstream report
- Filed as [elle-lisp/elle#999](https://github.com/elle-lisp/elle/issues/999) — "a map-returned list's tail is freed and reused after a recursive match walk over it". No prior issue covered it.
- ellc commit `fa82af08` (latest) reproduces.
- Triggers on the ORIGINAL hypervisor test `tests/elle/hypervisor-runtime.lisp`
  at 0b "executable PATH preflight" (three `graph:find-entry` calls in a `let*`).
- Suggested area: `src/vm/core/region.rs`, `src/hir/region/infer/*`,
  `src/value/fiberheap/*` — the region ownership pass.

## RESOLVED LOCALLY

Fixed in the local `.elle` checkout (uncommitted, 5 files under `src/lir/lower/`):
the corruption is the `region-match-rest-tail-move` UAF.

**Root cause** — a `match`-destructured `rest` alias (a `(a & rest)` pattern,
which the decision tree loads via the `Rest` intrinsic into the scrutinee's
region pages) carries NO owning reference, because the region solver only
registers a counted container read for *call-site* `rest()`/`first()`, not for
pattern loads. When such an alias is passed as an owned-param CALL ARGUMENT
(tail or not — a recursion `(f rest name)`, or `(sink rest)`), the callee's
owned-param release frees the caller's still-live scrutinee region → the
caller's original list is corrupted (tail cons cells freed/reused).

**Fix** — the lowerer tracks `destructure_alias_bindings`: any binding reached
through an `AccessPath::Rest` in the match decision tree (and the `Pair` /
`List` arm rest patterns) is marked borrowed, so `arg_leaf_is_borrowed` /
`tail_arg_is_borrowed` treat a call argument naming one as borrowed and mint a
fresh owning reference at the call (the borrowed-arg incref) that the callee's
release balances. The scrutinee's own reference is untouched.

**Files changed** (in `.elle`, uncommitted):
- `src/lir/lower/mod.rs` — new `destructure_alias_bindings` field
- `src/lir/lower/control.rs` — `arg_leaf_is_borrowed` consults the alias set
- `src/lir/lower/pattern.rs` — `access_has_rest()` helper + marks in decision tree
- `src/lir/lower/pattern/seq.rs` — marks `Pair`/`List` rest-pattern bindings
- `src/lir/lower/binding/destructure.rs` — marks `(def (a & r))` rest bindings
- `tests/elle/region-match-rest-tail-move-uaf.lisp` — regression test (NEW)

**Verified** — all original repros pass; the elle region/match/map/tail family
(24 tests) passes; the hypervisor's own `tests/elle/hypervisor-runtime.lisp`
(all tests passed) passes. GitHub CI will run the full `make smoke`/`make test`.
