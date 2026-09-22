# How Jev Voice works

[← Back to the README](../README.md)

## Observe, choose, act, verify


1. Apple on-device speech recognition accumulates the full spoken request.
2. The app preserves that request verbatim. It does not split it into scripted tasks.
3. It discovers installed applications and reads the current app's Accessibility tree: controls, menu items, windows, fields, values, and exposed actions.
4. It supplies these actions plus generic keyboard, scrolling, dragging, typing, waiting, and completion choices to Jev.
5. Jev picks one action. Parameter choices (text, complete key combinations, drag targets) also go to Jev.
6. The app executes that primitive and observes its result. The next Jev choice includes completion alongside actions from the fresh catalogue, with the unchanged original request and history.
7. Jev selects completion. A separate Jev check compares the current screen against the entire request and its literal values before the app reports success.

There are no website aliases, app-specific task recipes, navigation macros, command-to-action regular expressions, or automatic completion after typing/launching. The capability catalogue does not take the request as an argument. The small fixed vocabulary is the execution machinery itself: physical keys, pointer events, Accessibility APIs, and voice session controls such as “cancel task.”

## Options and typing

Every discovered option is retained. Jev's 255-choice limit is handled by groups: compact action labels select a group; full descriptions select the action. Generic operations remain directly selectable. Large catalogues route through operation categories and alphabetical target groups. Only the selected branch is evaluated, avoiding exhaustive parallel nominations. Every discovered leaf remains reachable. Category and group selection execute nothing; UI actions remain sequential. Accessibility scans have a time/node budget and explicitly report incomplete scans; Jev can request a deeper scan.

Typing is also selection. Insertion and whole-field replacement are separate choices. Replacement selects all text, verifies that selection, pastes the chosen literal, and verifies the resulting field value; it never submits automatically. Jev selects a source (your request or observed text), the first token, then the complete substring to insert. Code preserves its spelling, punctuation and internal whitespace. Typing does not switch apps, focus another field, submit, navigate, or silently add a domain. “Open YouTube” can therefore lead to entering “YouTube” in a browser and following a search result. A website mapping does not supply “youtube.com.”

Jev cannot generate new prose or understand screenshots. Original writing, custom-drawn/inaccessible controls, arbitrary pixel-level editing and unrestricted human-equivalent operation are **not** supported. Some UI trees provide incomplete or stale information. This app is a general Accessibility-based action picker, not a guarantee that every task will succeed. Secure fields are excluded. Pointer targets are checked; uncertain text insertion stops to prevent duplication. Model completion checks reduce false success but are not infallible.
