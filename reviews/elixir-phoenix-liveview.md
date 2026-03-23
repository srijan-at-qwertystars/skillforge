# Review: phoenix-liveview

Accuracy: 4/5
Completeness: 4/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.5/5

Issues:

1. **Incorrect LiveComponent process claim (SKILL.md line 144)**
   Text: "LiveComponents have overhead from their own process lifecycle."
   LiveComponents do NOT have their own process — they run inside the parent LiveView's process. The overhead comes from the component lifecycle management (update/preload callbacks, state tracking), not from a separate process. A crash in a LiveComponent brings down the parent LiveView.
   Fix: "LiveComponents add overhead from their lifecycle management (update callbacks, state tracking)."

2. **`scripts/` and `assets/` not linked from SKILL.md**
   The Resources section (line 500) references `references/` files but never mentions the `scripts/` directory (check-liveview-antipatterns.sh, generate-live-component.sh, generate-liveview.sh) or the `assets/` directory (form_live_view.ex, hooks.js, live_component_template.ex, live_view_template.ex, upload_live_view.ex). An AI consumer would not discover these supporting files.

3. **Missing gotcha: LiveComponents cannot receive messages**
   LiveComponents lack `handle_info/2` since they share the parent process. This is a common pitfall for engineers expecting component-level PubSub handling. Should be listed in the anti-patterns/gotchas section.

4. **Missing `on_mount` hooks for authentication**
   The skill covers lifecycle thoroughly but omits `on_mount` — the standard pattern for authentication guards on LiveViews. This is a critical pattern for any production app.

5. **Minor: `@impl true` missing on `handle_event("save", ...)` in assets/form_live_view.ex line 66**
   Inconsistent with the skill's own anti-pattern check (#6 in check-liveview-antipatterns.sh) and the advice in SKILL.md.

6. **Minor: Version compatibility could be more precise**
   SKILL.md says "requires Phoenix 1.7+, Elixir 1.14+". LiveView 1.1 is designed for Phoenix 1.8+. While 1.7 may work, the colocated hooks feature (documented in the skill) requires 1.8+.

## Structure Assessment

- ✅ YAML frontmatter has `name` and `description`
- ✅ Description includes positive AND negative triggers
- ✅ Body is 486 lines (under 500 limit)
- ✅ Imperative voice, no filler
- ✅ Comprehensive examples with input/output
- ⚠️ `scripts/` and `assets/` not linked from SKILL.md

## Trigger Assessment

- ✅ Would trigger for "build a real-time dashboard in Elixir"
- ✅ Would trigger for "add live form validation"
- ✅ Would trigger for "Phoenix LiveView streams pagination"
- ✅ Would NOT falsely trigger for plain Phoenix controllers, Absinthe, or non-Elixir frameworks
- ✅ Negative triggers are clearly scoped

## Content Verification (web-searched)

- ✅ Lifecycle callback order is correct (mount → handle_params → render → handle_event/handle_info)
- ✅ Current stable version is v1.1.x (latest 1.1.27) — matches skill claim
- ✅ Streams API signatures (stream_insert/4, stream_delete/3) are accurate
- ✅ Colocated hooks syntax and feature attribution to LiveView 1.1 is correct
- ✅ `stream_insert` with `limit` option is a real API
- ✅ HEEx syntax examples are valid
- ❌ LiveComponent process claim is factually wrong

## Summary

Excellent skill overall. Deep, practical, and well-structured. The LiveComponent process misstatement is the only factual error. The missing `scripts/` and `assets/` links reduce discoverability of valuable supporting resources. Adding `on_mount` and the LiveComponent `handle_info` limitation would make the gotchas section complete.
