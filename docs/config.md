# The config panel

`cprof config` opens an interactive panel over `~/.cprof.json`. You move
through the settings, type a new value, and watch the real statusline change
before you commit to it. It is the quickest way to tune the statusline without
remembering key names.

It needs [fzf](https://github.com/junegunn/fzf) (`brew install fzf`) and a
terminal. Without either, `cprof config` prints a message saying so and exits
with status 0; every setting is still reachable through the subcommands and by
editing the JSON file, so nothing depends on the panel.

## What it edits

The panel covers two things.

- **The statusline.** The `statusline` block of `~/.cprof.json`: the bar's
  glyphs and width, the warn and critical thresholds, the point where the
  weekly bar appears, the five text colours, the `agents` limits, and the line
  layout. See [Statusline](statusline.md#configuration) for what each setting
  means.
- **The default profile.** The same setting `cprof default <name>` writes.

The line layout is a screen of its own. Each row is one line, shown as its
segments separated by spaces. To edit a line, type its segments space-separated
(`badge dir git`); an empty value removes the line. The last row, "add a line",
appends a new one.

Not in this version: profiles, rules, pins, fallback, and add, remove, login
and share. Those still use their own subcommands; see [Commands](commands.md).

## Using it

Run `cprof config`. The main screen lists the statusline and the default
profile. Enter opens a screen or edits a row, and Esc goes back (or quits, on
the main screen). Editing a row opens a value picker: type the value, and for
colours, profiles and segment names the valid choices are listed beside it.
Enter applies, Esc cancels.

### The live preview

The pane under the list shows the real statusline as it would look, rendered
by the same code that renders it in Claude Code, and it updates as you type.
Under it, the preview names the setting, its kind and its accepted range, and
lists any problem the value would cause.

The preview always shows the value Enter will write. For colours and
profiles, a query that names a choice exactly is that value. Otherwise (a
partial or empty query) Enter writes the highlighted choice when there is one,
and the preview renders that choice rather than what you typed.

The panel usually runs in a plain terminal, where there is no session profile
to render for. The preview then renders as your default profile, or as the
first profile when no default is set. With no profile configured at all it says
`no profile configured: the statusline renders only for a cprof profile`.

For the default profile the preview shows the profile's name, its directory (or
`native`) and its cached 5-hour usage. It reads only the cache and never calls
the usage endpoint.

## Writes, backup and undo

A value is written the moment you press Enter. Before each write, the previous
file is copied to `~/.cprof.json.bak`, and the header reports the result.
Applying a value that is already in effect does nothing: the header says
`unchanged; nothing written`, and the backup is kept, so the last real change
can still be undone.

`cprof config undo` puts that backup back and removes it. The current file is
not kept, so an undo cannot itself be undone, and undo is one step deep: a
second undo, or one before any write, reports `nothing to undo` and changes
nothing. A write that fails leaves the existing backup alone.

A value `cprof` would reject is refused, and nothing is written. A statusline
setting is refused with the same message `cprof doctor` gives for it; a default
profile that does not exist is refused as `cprof default` refuses it, with
`unknown profile <name>`. An advisory that the resolver still accepts, such as
the `agents` segment sharing a line, does not block a write.

## Scripting

`--rows`, `--preview`, `--preview-pick` and `--apply` are the panel's own
callbacks, which fzf calls to fill the list, draw the previews and write a
value. They are not a
scripting interface, and their ids may change between releases. Scripts should
use the subcommands (`cprof default`, `cprof color`, and so on) or edit the JSON
file.
