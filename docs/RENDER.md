# Rendering the menu

The menu is a native macOS menu, so it cannot be captured from a test. `tools/render.sh` renders what matters offscreen instead: the menu's header, summary, actions and rows, and the hover card of five made-up worktrees in two made-up repos, in light and dark.

```sh
tools/render.sh              # PNGs in build/render, and the first-day state in build/render/first-day
```

`tools/render.m` builds the worktrees and the review in memory, so nothing on the Mac is scanned and no model is asked. `Sources/main.m` is compiled with `-Dmain=xx_main`, and the render calls the menu code the app uses. Custom views render as they are. Plain items are drawn as title, subtitle and badge, an approximation of what macOS draws.

The pictures in the README are `menu-dark.png` and `card-checkout-dark.png` from this script. After a change to the menu, render it and look at every PNG: text readable, columns aligned, nothing cut off where it matters.
