# WP3 — Effects, Selective Reload, and Report UI Fixes

Scope: `elle/runtime-forms/emacs-hypervisor-selective-reload.el`,
`elle/runtime-forms/emacs-hypervisor-effect-registry.el`,
`elle/runtime-forms/emacs-hypervisor-effect-kind-keybinding.el`,
`elle/runtime-forms/emacs-hypervisor-effect-aware-reload.el`,
`elle/runtime-forms/emacs-hypervisor-reload-report.el`,
`elle/runtime-forms/emacs-hypervisor-report.el`,
`tests/elisp/emacs-hypervisor-bootstrap-test.el`.

Run tests with the invocation in `docs/improvements/README.md` (trampolines
disabled). Background reading: `docs/effect-system.md`, `docs/reload.md`.

## 3.1 Selective-reload identity is defeated by embedded effect provenance (BUG)

`emacs-hypervisor-selective-reload--identity-entry`
(`emacs-hypervisor-selective-reload.el:11-19`) strips only the top-level
`:source`/`:index` keys before `equal`-comparing units, relying on the
invariant "editing text above a unit shifts line numbers without changing the
unit."

That invariant breaks for any unit containing a tracked effect. The effect
rewrite closures bake a literal `:source (quote (:form ... :file ... :heading
... :line ...))` into the rewritten call inside the unit's `:body`:
`emacs-hypervisor-effect-aware-reload.el:88-91` (hook/advice via
`define-function-effect-kind`) and
`emacs-hypervisor-effect-kind-keybinding.el:52-54`. The embedded `:line` comes
from `emacs-hypervisor--current-source`
(`emacs-hypervisor-config-loader.el:108-114`), which equals the unit's own
(stripped) source line. Net effect: any edit above a unit changes its `:body`,
so `emacs-hypervisor-selective-reload-unit-equal-p` reports `:changed`, and the
unit is needlessly retracted and re-applied on every reload — precisely for the
units the effect system was built to protect.

**Required change** — add
`emacs-hypervisor-selective-reload--strip-effect-source (form)`: a recursive
walk (e.g. `cl-labels` over conses) that, wherever it finds a `:source` keyword
followed by `(quote PLIST)` (or `'PLIST`) in an argument position, replaces the
quoted plist with `nil`. Apply it to the `:body` value inside
`--identity-entry` before comparison. Prefer detecting the generic
`:source (quote ...)` keyword-argument shape over hardcoding the three
register-fn names (`emacs-hypervisor-register-hook-effect`,
`emacs-hypervisor-register-advice-effect`,
`emacs-hypervisor-register-keybinding-effect`), so future effect kinds are
covered automatically. The walk must not mutate the original body (use
copy-on-write reconstruction) and must handle improper lists/vectors gracefully
(leave them as-is).

**Tests**

1. Build two unit entries whose `:body` contains a
   `emacs-hypervisor-register-hook-effect` call identical except for the
   embedded `:source` line; assert
   `emacs-hypervisor-selective-reload-unit-equal-p` treats them as equal.
2. Same shape but with a genuinely different hook target; assert `:changed` is
   still detected.
3. Keep `emacs-hypervisor-selective-reload-ignores-source-and-index` passing.

## 3.2 Keybinding retraction reports success when it retracted nothing (BUG)

`emacs-hypervisor-effect-kind-keybinding--retract`
(`emacs-hypervisor-effect-kind-keybinding.el:118-153`) correctly refuses to
remove a binding that diverged from the recorded definition (lines 143-150,
warning only). But `emacs-hypervisor-effect-registry-retract`
(`emacs-hypervisor-effect-registry.el:151-159`) ignores the retract form's
return value: as long as `(eval retract)` doesn't signal, the record is marked
`:status :retracted` and counted as "cleaned" by
`emacs-hypervisor-effect-aware-reload-cleanup-count`
(`effect-aware-reload.el:205-206`) and logged as cleaned by
`emacs-hypervisor-reload-report.el:80-86`. The reload report claims a cleanup
that did not happen.

**Required change**

- Make the keybinding retract path return a discriminated result:
  `:retracted` when the binding was actually removed, `:diverged` when it was
  left in place. The retract form for the keybinding kind should evaluate to
  that sentinel.
- In `emacs-hypervisor-effect-registry-retract`, capture
  `(let ((result (eval retract t))) ...)` (note: also fixes the one-arg `eval`
  byte-compile warning). When `result` is `:diverged`, mark the record with a
  distinct status (e.g. `:status :diverged`) and route it to the same bucket as
  unsupported/skipped records rather than `:cleaned` — study
  `emacs-hypervisor-effect-registry-retract-unit` (registry.el:161-185) for
  where `:cleaned` vs other buckets are built. Hook/advice retract forms are
  plain `progn`s whose success is implicit; treat any non-`:diverged` result as
  retracted so their behavior is unchanged.
- Surface the divergence in the reload report/log ("left in place: ...") via
  `emacs-hypervisor-reload-report.el` so counts stay honest.

**Edge case to cover in tests, not necessarily fix code for:** two units
binding the same key to the same definition — retracting the first physically
removes the key; the second unit's later retraction then sees `nil` and warns
"changed outside Hypervisor" misleadingly. At minimum add a test documenting
current behavior; if a cheap fix exists (e.g. checking the registry for other
live records owning the identical binding before removal in `--retract`),
implement it.

**Tests** — (a) diverged binding: rebind the key to something else after
registration, retract the unit, assert the record is *not* counted in
`cleanup-count` and the binding survives; (b) normal retraction still counts
as cleaned; (c) hook/advice retraction counts unchanged.

## 3.3 Report buffer jumps to top on every refresh (BUG)

`emacs-hypervisor--render-report-buffer`
(`emacs-hypervisor-report.el:767-788`): `(goto-char (point-min))` at line 785
sits **outside** the `unless (equal (buffer-string) rendered)` guard, so every
refresh (fired for essentially every startup event — see
`emacs-hypervisor-report-core.el:170-245`) yanks point to line 1 even when
nothing changed, defeating the point-preserving purpose of
`replace-buffer-contents` (line 782) and contradicting the intent documented at
`report.el:790-793`.

**Required change** — restructure so:

- unchanged content ⇒ no point movement at all;
- `replace-buffer-contents` path ⇒ no explicit `goto-char` (it preserves
  point by design);
- the `erase-buffer`/`insert` fallback ⇒ keep `(goto-char (point-min))` (that
  path genuinely loses point).

**Test** — render once, move point into the middle of the buffer, call
`emacs-hypervisor--render-report-buffer` again with unchanged model; assert
point did not move. Existing
`emacs-hypervisor-report-render-skips-unchanged-buffer` must keep passing.

## 3.4 Dead/incorrect fallback code in reload-report formatting

`emacs-hypervisor--reload-effect-source-form`
(`emacs-hypervisor-reload-report.el:38-39`) reads `(plist-get effect
:source-form)`, but no effect record sets `:source-form` — records carry
`:source` (a plist with `:form`; see
`emacs-hypervisor-effect-aware-reload-source-plist`, `aware-reload.el:19-20`).
Consequently the `nth`-based fallbacks in `--reload-effect-target`,
`--reload-effect-function`, `--reload-effect-where`
(`reload-report.el:41-54`) are permanently dead. Also, the
`:generated-function` branch of `emacs-hypervisor--reload-format-effect`
(`reload-report.el:74-76`) is unreachable — `:generated-function` is a
metadata flag (registry.el:210-211), never a `:kind`.

**Required change** — fix the accessor to
`(plist-get (plist-get effect :source) :form)` so the documented fallback path
actually works for future effect kinds; delete the unreachable
`:generated-function` kind branch. Add a small test feeding a synthetic effect
record that carries only `:source` (no `:target`/`:function`) and assert the
fallback extracts target/function/where from the form.

## Acceptance criteria

- Full ERT suite passes (trampolines disabled) including the new tests.
- A unit whose only change is line-number drift is reported `:unchanged` by
  selective reload even when it registers hook/advice/keybinding effects.
- Reload cleanup counts never include keybinding effects that were left in
  place.
- Point in an open report buffer survives refreshes with unchanged content.
