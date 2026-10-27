# Rules file

`~/Library/Application Support/WorkForest/rules.json` is written with defaults on first run, and *Edit Rules…* in the menu opens it. New defaults arrive with upgrades and never remove an entry of yours.

```json
{ "roots":   ["~/Documents/GitHub", "~/Developer", "~/code", "~/src", "~/Projects", "~/repos", "~/dev"],
  "depth":   3,
  "protect": { "paths": ["~/code/acme-web.worktrees/search-facets"],
               "branches": ["main", "master", "develop", "staging", "production", "release", "…"] },
  "ignore":  { "paths": ["~/code/archive"] },
  "caches":  ["node_modules", ".next", ".svelte-kit", ".turbo", "dist", "build", "target", "_build", "deps", ".venv", "…"] }
```

- **roots** are the folders scanned for repos, and **depth** is how many levels below each one to look. A repo's own worktrees are found through git wherever they are.
- **protect.paths** never removes a worktree at or under a path. *Protect* in a row's submenu adds its path.
- **protect.branches** never removes a worktree with a branch of that name checked out.
- **ignore.paths** leaves worktrees under a path out of the list entirely.
- **caches** are folder names whose contents can be rebuilt. Their size counts as cache, their changes are not work, and they are not saved before a removal. A file changed inside node_modules does not keep a worktree.
