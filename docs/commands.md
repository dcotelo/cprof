# Commands

| Command | Description |
| --- | --- |
| `cprof list` | Profiles with identity, subscription, usage (5h/7d), and markers; marks default, active, native |
| `cprof which` | Profile resolved here, and the rule that produced it |
| `cprof status` | Profile this process is actually running as |
| `cprof env` | `export`/`unset` statements for `eval` |
| `cprof add <name> [--dir P] [--native] [--note S] [--isolated]` | Register a profile |
| `cprof share <name>` / `unshare <name>` | Link `~/.claude` customisations into a profile, or drop the links |
| `cprof color <name>` | Pick a profile's colour interactively |
| `cprof color <name> <colour>` | Set it directly; `auto` returns to the hashed colour |
| `cprof color --text on\|off` | Whether the statusline badge's name is coloured too; on by default |
| `cprof default <name>` | Set the default profile |
| `cprof pin [<name>] \| pin --clear` | Pin or unpin this repository |
| `cprof rule add <path> <name>` | Route a directory tree to a profile |
| `cprof rules` / `rule list` | Rules in the order resolution consults them |
| `cprof rule rm <path>` | Drop a rule |
| `cprof login <name>` | Sign a profile in, with keychain protection |
| `cprof doctor` | Report unauthenticated profiles, expiring tokens, any profile at 90% or more of its 5-hour usage window, and a statusline setting that did not take |
| `cprof usage [<name>]` | Usage bars (5h/7d) for every profile, or the full breakdown for one |
| `cprof usage --render <name>` | Cache-only: a profile's 5h percentage, bar, and colour code, tab-separated, for the statusline; never calls the usage endpoint |
| `cprof statusline [--stdin]` | The whole statusline: account, model, directory and branch, context and usage |
| `cprof fallback <primary> [<name>\|--clear]` | Show, set, or clear a live-swap fallback for when `<primary>` runs out of usage headroom |
| `cprof update` | Refresh the marketplace, then update this plugin |
| `cprof remove <name> [--purge]` | Unregister; `--purge` deletes the directory |

In a session, `/profile` shows status, `/profile pin <name>` pins the repository.

`which` answers "what should this directory use", `status` answers "what am I
signed in as right now". They disagree after you pin or add a rule without
relaunching — which is exactly when knowing the difference matters.

Listings size their columns to the contents, so a long profile name widens the
table instead of breaking the alignment, and paths under your home print as `~`.
