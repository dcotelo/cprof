#!/usr/bin/env bash
# shellcheck shell=bash
# The full statusline: everything cprof can say about a session, rendered by
# one `cprof` invocation where the one-line segment spent three. `cprof
# statusline` is the entry point; statusline/segment.sh --full is a thin
# wrapper around it.
#
# Claude Code re-runs a statusline every few seconds, so this file spends
# processes carefully: one jq pass for the payload metadata, one for the usage
# figures, and two git calls only when a working tree is actually there.

# cp_sl_meta_fields: a Claude Code statusline payload on stdin -> either
# nothing at all, or exactly two tab-separated fields, the model display name
# and the current directory. Callers read both with `cut`, which yields an
# empty field either way, so a malformed payload needs no special case here.
cp_sl_meta_fields() {
  jq -r '
    def s(v): if (v|type) == "string" and (v|length) > 0 and (v|length) <= 200
                and ((v|explode|map(select(. < 32))|length) == 0)
              then v else "" end;
    [s(.model.display_name), s(.workspace.current_dir // .cwd)] | @tsv
  ' 2>/dev/null
}

# cp_sl_dir_label <dir> -> what to show for it: the last path segment, or ~
# for the home directory itself. A statusline has one line to spend, and the
# leading path is the part that is the same in every session.
cp_sl_dir_label() {
  local dir="${1:-}"
  [ -n "$dir" ] || return 0
  [ "$dir" = "$HOME" ] && { printf '~\n'; return 0; }
  printf '%s\n' "${dir##*/}"
}

# cp_sl_git_fields <dir> -> "<branch>\t<dirty>", nothing when <dir> is not in
# a working tree. `dirty` is `*` or empty.
cp_sl_git_fields() {
  local dir="${1:-}" branch='' dirty=''
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  command -v git >/dev/null 2>&1 || return 0
  # An unborn branch (a fresh `git init`) has no HEAD to resolve, so
  # rev-parse fails where symbolic-ref still answers. A detached HEAD is the
  # other way round: symbolic-ref fails and the short sha is what to show.
  branch="$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null)" \
    || branch="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)" \
    || return 0
  [ -n "$branch" ] || return 0
  # The first line of output is all it takes to know the tree is not clean,
  # and stopping there keeps the cost bounded on a large repository.
  [ -n "$(git -C "$dir" status --porcelain 2>/dev/null | head -1)" ] && dirty='*'
  printf '%s\t%s\n' "$branch" "$dirty"
}

# cp_sl_bar <bar> <sgr-code> <empty-glyph> -> the bar with its filled run in
# the severity colour and its remainder dim, so the empty part reads as
# background rather than as a second value. Plain when there is no colour.
# The empty glyph is a parameter because it is configurable: cutting at a
# hardcoded one would colour the whole bar as filled.
cp_sl_bar() {
  local bar="${1:-}" code="${2:-}" empty_g="${3:-░}" filled rest
  if [ -z "$bar" ] || [ -z "$code" ]; then
    printf '%s\n' "$bar"
    return 0
  fi
  filled="${bar%%"$empty_g"*}"
  rest="${bar#"$filled"}"
  printf '\033[%sm%s\033[2m%s\033[0m\n' "$code" "$filled" "$rest"
}

# cp_sl_config <cfg> -> four lines of resolved configuration:
#   1  layout:     segments space-separated, lines joined by ';'
#   2  bar:        filled<TAB>empty<TAB>width
#   3  thresholds: warn<TAB>critical
#   4  colours:    model<TAB>dir<TAB>git<TAB>branch<TAB>label   (names)
#
# One jq pass, so a tick spends one call here and the renderers never read a
# raw value. Every rejected value is replaced by its default and nothing is
# said about it: this runs every few seconds with its stderr discarded, so a
# warning here would be invisible and endless. `cprof doctor` does the
# reporting instead, from cp_sl_config_problems.
#
# Colour names, not SGR parameters: cp_color_code owns that mapping and knows
# the palette `cprof color` documents. `dim` is the one name it does not
# carry, and the renderers translate it. A colour name over 20 characters is
# rejected too: that length is not part of the documented palette, it is a
# defensive bound against an untrusted config, and it fails the same way
# every other rejected value does -- silently, to its default.
#
# Every default below is a shell variable, defined exactly once, passed into
# the jq program with --argjson/--arg and reused to build the fallback for a
# config the jq program cannot resolve. That fallback derives its layout line
# from the same JSON the jq program uses, rather than a second hand-typed
# copy, so the two paths cannot silently drift apart.
#
# The four lines are all or nothing, which is why the jq output is captured
# instead of being piped straight out. jq prints the results of a
# comma-separated expression one at a time, so a program that errors partway
# -- which is what indexing a wrongly typed section does -- has already
# printed the lines before the error. Appending the fallback to those would
# hand every positional consumer a line from the wrong row: with a `bar`
# that is a string, the layout line lands where the bar configuration
# should be and the statusline draws its usage bar out of the layout string.
# So the resolved lines are used only when jq succeeded and produced exactly
# four of them. No value the jq program keeps can carry a newline of its own
# any more -- clean() refuses every character below 32 -- so that count is
# belt and braces now rather than the thing standing between a configured
# newline and a consumer reading the wrong row.
cp_sl_config() {
  local cfg="${1:-}" out rc=0 four=0 nl
  local d_layout='[["badge","model","dir","git"],["context","usage"]]'
  local d_fill='▓' d_empty='░' d_width=10 d_warn=70 d_crit=90
  local d_model=cyan d_dir=yellow d_git=magenta d_branch=cyan d_label=dim
  nl='
'
  [ -n "$cfg" ] || cfg='{}'
  out="$(printf '%s' "$cfg" | jq -r \
    --argjson deflayout "$d_layout" \
    --arg fill "$d_fill" --arg empty "$d_empty" \
    --argjson width "$d_width" --argjson warn "$d_warn" --argjson crit "$d_crit" \
    --arg model "$d_model" --arg dir "$d_dir" --arg git "$d_git" \
    --arg branch "$d_branch" --arg label "$d_label" '
    def known: ["badge","model","dir","git","context","usage"];
    # Nothing below character 32 in a value that is kept. These four lines are
    # read by their delimiters, and an invisible character collides with them:
    # a tab shifts every field after it on its row -- so the directory colour
    # would take the value meant for the branch and the label colour would
    # fall off the end -- and a newline forges a row outright. A tab also passes "one
    # character" on its own terms, which is how one reached the bar glyphs.
    # explode, not a regex: jq 1.5 has no regex functions.
    def clean($v): ($v|type) == "string" and (($v|explode|map(select(. < 32))|length) == 0);
    def pick($v; $d): if clean($v) and ($v|length) > 0 and ($v|length) < 20
                      then $v else $d end;
    def glyph($v; $d): if clean($v) and ($v|length) == 1 then $v else $d end;
    def whole($v; $lo; $hi; $d): if ($v|type) == "number" and $v == ($v|floor)
                                    and $v >= $lo and $v <= $hi
                                 then $v else $d end;
    (.statusline // {}) as $s
    | (if ($s.lines|type) == "array" then $s.lines else [] end) as $raw
    | ([ $raw[] | select(type == "array")
         | [ .[] | select(type == "string") | select(. as $seg | known | index($seg)) ]
         | select(length > 0) ]) as $clean
    | (if ($clean|length) > 0 then $clean else $deflayout end) as $layout
    | ($s.bar // {}) as $b
    | ($s.thresholds // {}) as $t
    | ($s.colors // {}) as $c
    | (whole($t.warn; 1; 100; 0)) as $w
    | (whole($t.critical; 1; 100; 0)) as $cr
    | (if $w > 0 and $cr > 0 and $w < $cr then [$w, $cr] else [$warn, $crit] end) as $th
    | ([ $layout[] | join(" ") ] | join(";")),
      ([glyph($b.filled; $fill), glyph($b.empty; $empty),
        (whole($b.width; 1; 40; $width) | tostring)] | join("\t")),
      ($th | map(tostring) | join("\t")),
      ([pick($c.model; $model), pick($c.dir; $dir), pick($c.git; $git),
        pick($c.branch; $branch), pick($c.label; $label)] | join("\t"))
  ' 2>/dev/null)" || rc=$?
  case "$out" in
    *"$nl"*"$nl"*"$nl"*"$nl"*) ;;
    *"$nl"*"$nl"*"$nl"*) four=1 ;;
  esac
  if [ "$rc" -eq 0 ] && [ "$four" -eq 1 ]; then
    printf '%s\n' "$out"
    return 0
  fi
  printf '%s\n%s\t%s\t%s\n%s\t%s\n%s\t%s\t%s\t%s\t%s\n' \
    "$(printf '%s' "$d_layout" | jq -r '[.[] | join(" ")] | join(";")')" \
    "$d_fill" "$d_empty" "$d_width" "$d_warn" "$d_crit" \
    "$d_model" "$d_dir" "$d_git" "$d_branch" "$d_label"
}

# cp_sl_config_problems <cfg> -> one line per rejected statusline setting,
# nothing when the block is absent or wholly valid. The statusline itself is
# silent by design (see cp_sl_config), so this is where a reader finds out
# that a setting did not take.
#
# One rule, at every level -- the block, each section, and each field inside
# each section:
#
#   absent, or an explicit null   nothing was configured here, so say
#                                 nothing: that is exactly what cp_sl_config
#                                 makes of it
#   kept by the resolver          say nothing
#   anything else                 configured, and the resolver put something
#                                 else in its place: name the key and the
#                                 value it used instead
#
# So an empty string and a false are configured values that were rejected,
# not absent ones, and both are reported.
#
# "The resolver put something else in its place" is not a second, hand-typed
# reading of the resolver rules: for every scalar field it is literally
# `rejected(written; resolved)`, where the resolved value is computed by the
# same expression cp_sl_config uses. A shape nobody anticipated is therefore
# judged by the resolver rather than by a case list. The fallback each
# message names comes from `cp_sl_config {}` for the same reason, so a
# message cannot drift from the value the resolver actually substitutes.
#
# A key cprof does not read at all is the one report that is not about a
# value: the resolver ignores it in silence, so there is no fallback to name,
# and what a reader needs is the key and the level it was written at. Every
# level inside the block gets that check -- the block, `bar`, `thresholds`
# and `colors` -- because a misspelled key is the most common real
# misconfiguration there is, and staying silent about it while naming an
# unknown segment teaches a reader to trust a check that was not there. An
# unknown key at the top level of the config, outside the block, is a
# question about the whole config schema and is deliberately not asked here.
#
# Every name a message carries -- a key, a segment, a colour -- is quoted and
# escaped on the way out, which is why they read `unknown key "wdith"`. See
# safe() below: this function reports on an untrusted file, so nothing out of
# that file may write a line of its own here.
#
# `lines` is the one setting that cannot be judged that way, because the
# resolver honours a layout partially: it keeps every inner array that has
# at least one known segment and drops the rest. So it gets the same $clean
# computation the resolver performs -- a fallback is a $clean that came out
# empty -- plus one line per unknown segment.
#
# Every section is type-checked before it is indexed. cp_sl_config can get
# away with indexing straight through, because a crash partway through its
# jq program is caught whole by its blanket `|| printf <defaults>` -- the
# entire resolved config falls back together, so nothing there depends on
# the jq program finishing normally. This function has no such net: a crash
# partway through would silently drop every report queued after the crash
# point, in a function whose entire purpose is to not be silent. So a wrongly
# typed `statusline`, `bar`, `thresholds` or `colors` value gets its own
# guard and its own line, naming the default the resolver actually falls
# back to, and one bad section can never suppress another's report.
cp_sl_config_problems() {
  local cfg="${1:-}" key name default state colors_ok tab defaults esc_def
  local d_fill='' d_empty='' d_width='' d_warn='' d_crit=''
  local d_model='' d_dir='' d_git='' d_branch='' d_label=''
  tab="$(printf '\t')"
  # The fallbacks these messages name are read off the resolver itself,
  # rather than typed out a second time here where they could drift.
  defaults="$(cp_sl_config '{}')"
  {
    read -r _
    IFS="$tab" read -r d_fill d_empty d_width
    IFS="$tab" read -r d_warn d_crit
    IFS="$tab" read -r d_model d_dir d_git d_branch d_label
  } <<EOF
$defaults
EOF
  # Every message below names the value the resolver substituted. Handed no
  # defaults at all, there is nothing honest to report: a message with an
  # empty fallback in it would be worse than silence. So say nothing rather
  # than repeating the ten defaults here as a third hand-typed copy, which
  # could only drift from the resolver it is meant to describe.
  if [ -z "$d_fill" ] || [ -z "$d_empty" ] || [ -z "$d_width" ] \
     || [ -z "$d_warn" ] || [ -z "$d_crit" ] || [ -z "$d_model" ] \
     || [ -z "$d_dir" ] || [ -z "$d_git" ] || [ -z "$d_branch" ] \
     || [ -z "$d_label" ]; then
    return 0
  fi
  # Every name below that came out of the configuration file reaches the
  # output through safe(), which hands it back quoted and escaped. Without
  # that, a key name carrying a newline printed a second line that read
  # exactly like a genuine finding: a configuration file forging the output of
  # the one function whose job is honest reporting. Escaped, not filtered by a
  # wider character predicate -- a predicate has to be widened again for the
  # next character class, and safe() is total over every code point. The
  # resolver's own `< 32` rule stays as it is: it guards the four resolved
  # lines' delimiters, which is a different job from this one.
  #
  # tojson does the quoting, and the escaping of everything below 32 plus the
  # quote, the backslash and DEL. What it leaves raw is every code point from
  # 128 up, and a right-to-left override among those visually reorders the
  # rest of the line it lands in, so those are escaped here too. Nothing
  # legible is lost: the names these messages carry are keys, segment names
  # and colour names, and every one cprof recognises is ASCII. A code point
  # above the basic plane is written as the surrogate pair JSON spells it
  # with.
  #
  # One copy, in a shell variable, because two jq programs below need it and
  # the colour reports have to be built in bash.
  # shellcheck disable=SC2016 # a jq program: $n, $v, $c and $u are jq variables
  esc_def='
    def hex4($n): [$n / 4096, $n / 256, $n / 16, $n]
      | map(floor % 16 | if . < 10 then . + 48 else . + 87 end) | implode;
    def uesc($c): if $c > 65535
                  then (($c - 65536) as $u
                        | "\\u" + hex4(55296 + (($u / 1024) | floor))
                          + "\\u" + hex4(56320 + ($u % 1024)))
                  else "\\u" + hex4($c) end;
    def safe($v): [ ($v | tojson) | explode[]
                    | if . < 128 then ([.] | implode) else uesc(.) end ]
                  | join("");
  '
  printf '%s' "$cfg" | jq -r \
    --arg fill "$d_fill" --arg empty "$d_empty" --argjson width "$d_width" \
    --argjson warn "$d_warn" --argjson crit "$d_crit" "$esc_def"'
    def known: ["badge","model","dir","git","context","usage"];
    # The resolver rules, as cp_sl_config states them, so that a value is
    # judged by what the resolver did with it and not by a second reading.
    def clean($v): ($v|type) == "string" and (($v|explode|map(select(. < 32))|length) == 0);
    def glyph($v; $d): if clean($v) and ($v|length) == 1 then $v else $d end;
    def whole($v; $lo; $hi; $d): if ($v|type) == "number" and $v == ($v|floor)
                                    and $v >= $lo and $v <= $hi
                                 then $v else $d end;
    # null, explicit or from an absent key, means nothing configured here at
    # every level, and defaults quietly, the way the resolver does with its
    # own `// $d`. This is deliberately not that `//`, whose falsy set
    # covers false as well: a false is a configured value that was rejected.
    def ifnull($x; $d): if $x == null then $d else $x end;
    # The whole rule, in one line: a configured value that the resolver did
    # not keep.
    def rejected($v; $resolved): $v != null and $v != $resolved;
    # A section of any other type can be read past safely here, which is how
    # this function reports one without crashing the way the resolver does.
    def obj($x): if ($x|type) == "object" then $x else {} end;
    # A value the length rules would have kept -- a glyph is one character, a
    # colour name is one to nineteen -- and that clean() rejects for carrying
    # an invisible character. It needs its own message: "must be exactly one
    # character" is not the truth about a tab, which is exactly one character.
    def invisible($v; $lo; $hi): ($v|type) == "string" and ($v|length) >= $lo
                                 and ($v|length) <= $hi and (clean($v) | not);
    (ifnull(.statusline; {})) as $s
    | if ($s|type) != "object" then
        "statusline: not a JSON object; using the default configuration"
      else
        # Two ways for the block to be discarded whole rather than setting
        # by setting, both worth a line of their own: naming only the
        # section at fault would leave a reader wondering why the layout
        # they wrote correctly did not take either.
        ( if ( [$s.bar, $s.thresholds, $s.colors]
               | map(. != null and . != false and (type != "object")) | any )
          then "statusline: a section that is not a JSON object takes the whole block with it; using the default configuration"
          else empty end ),
        # A key nobody recognises is a typo often enough that silence is a
        # trap. Doctor already names an unknown segment, which teaches a
        # reader that it catches names it does not know -- and then said
        # nothing about `wdith`. So an unknown key is named too, at whichever
        # level it was written: one expression per level, each carrying the
        # keys known at that level. `keys` sorts, so two typos at one level
        # come out in a fixed order. A section that is not an object is read
        # past with obj(), because it is reported as a whole one line above
        # and has no keys to mine. The key is bound to $k before the list is
        # piped in, the way the unknown-segment check binds $seg: inside the
        # pipe `.` is the list, and index() given a list looks for it as a
        # subsequence instead.
        ( $s | keys[] | select(. as $k | ["lines","bar","thresholds","colors"] | index($k) | not)
          | "statusline: unknown key \(safe(.)) (known: lines bar thresholds colors)" ),
        ( obj($s.bar) | keys[] | select(. as $k | ["filled","empty","width"] | index($k) | not)
          | "statusline.bar: unknown key \(safe(.)) (known: filled empty width)" ),
        ( obj($s.thresholds) | keys[] | select(. as $k | ["warn","critical"] | index($k) | not)
          | "statusline.thresholds: unknown key \(safe(.)) (known: warn critical)" ),
        # `badge` is accepted here and ignored, deliberately: the badge takes
        # its colour from `cprof color`, so that a profile colour lives in one
        # place. It is tolerated rather than offered, so it is in the list this
        # check accepts but not in the list the message prints.
        ( obj($s.colors)
          | keys[] | select(. as $k
                     | ["model","dir","git","branch","label","badge"] | index($k) | not)
          | "statusline.colors: unknown key \(safe(.)) (known: model dir git branch label)" ),
        ( if $s.lines == null then empty
          elif ($s.lines|type) != "array"
          then "statusline.lines: not a list of segment lists; using the default layout"
          else ( [ $s.lines[] | select(type == "array")
                   | [ .[] | select(type == "string")
                       | select(. as $seg | known | index($seg)) ]
                   | select(length > 0) ] ) as $clean
               | if ($clean|length) == 0
                 then "statusline.lines: not a list of segment lists; using the default layout"
                 else empty end
          end ),
        ( if ($s.lines|type) == "array"
          then ( [ $s.lines[] | select(type == "array") | .[] | select(type == "string") ]
                 | map(select(. as $seg | known | index($seg) | not)) | unique | .[]
                 | "statusline.lines: unknown segment \(safe(.)) (known: badge model dir git context usage)" )
          else empty end ),
        ( (ifnull($s.bar; {})) as $b
          | if ($b|type) != "object"
            then "statusline.bar: not a JSON object; using \($fill), \($empty) and \($width)"
            else
              ( if rejected($b.filled; glyph($b.filled; $fill))
                then (if invisible($b.filled; 1; 1)
                      then "statusline.bar.filled: must not contain an invisible character such as a tab; using \($fill)"
                      else "statusline.bar.filled: must be exactly one character; using \($fill)" end)
                else empty end ),
              ( if rejected($b.empty; glyph($b.empty; $empty))
                then (if invisible($b.empty; 1; 1)
                      then "statusline.bar.empty: must not contain an invisible character such as a tab; using \($empty)"
                      else "statusline.bar.empty: must be exactly one character; using \($empty)" end)
                else empty end ),
              ( if rejected($b.width; whole($b.width; 1; 40; $width))
                then "statusline.bar.width: must be a whole number from 1 to 40; using \($width)"
                else empty end )
            end ),
        ( $s.thresholds as $t
          | if $t == null then empty
            elif ($t|type) != "object"
            then "statusline.thresholds: not a JSON object; using \($warn) and \($crit)"
            else ( whole($t.warn; 1; 100; 0) ) as $w
                 | ( whole($t.critical; 1; 100; 0) ) as $cr
                 | ( if $w > 0 and $cr > 0 and $w < $cr then [$w, $cr] else [$warn, $crit] end ) as $th
                 | if rejected($t.warn; $th[0]) or rejected($t.critical; $th[1])
                   then "statusline.thresholds: warn must be a whole number below critical, both from 1 to 100; using \($warn) and \($crit)"
                   else empty end
            end )
      end
  ' 2>/dev/null
  # Colours last, and in bash: cp_sl_code decides what a usable name is, and
  # the resolver resolves a colour in two stages, so a colour falls back in
  # two ways. pick() replaces a value it would never consider -- not a
  # string, empty, 20 characters or more, or carrying an invisible character
  # (which gets its own message, since "not a usable colour name" would leave
  # someone who typed a trailing tab after `red` none the wiser) -- with that
  # key's own default colour, which is what the first message names. A name pick() keeps but
  # the palette does not know is rendered plain instead, which is the
  # second. `null` is nothing configured at either level, as everywhere
  # else; `false` is a rejected value, as everywhere else.
  # `noplain` is `ok` with one report withheld: when the block was discarded
  # whole (see above), every colour comes out of the defaults, so a name that
  # is not in the palette is not being rendered plain and saying so would be
  # the one per-key message that a discarded block makes false. The others
  # all name a default, which is exactly what a discarded block uses.
  colors_ok="$(printf '%s' "$cfg" | jq -r '
    def ifnull($x; $d): if $x == null then $d else $x end;
    (ifnull(.statusline; {})) as $s
    | if ($s|type) != "object" then "skip"
      else ( (ifnull($s.colors; {})) as $c
             | if ($c|type) != "object" then "bad"
               elif ( [$s.bar, $s.thresholds, $s.colors]
                      | map(. != null and . != false and (type != "object")) | any )
               then "noplain"
               else "ok" end )
      end
  ' 2>/dev/null)"
  case "$colors_ok" in
    bad)
      printf 'statusline.colors: not a JSON object; using the defaults: model %s, dir %s, git %s, branch %s, label %s\n' \
        "$d_model" "$d_dir" "$d_git" "$d_branch" "$d_label"
      ;;
    ok|noplain)
      for key in model dir git branch label; do
        case "$key" in
          model)  default="$d_model" ;;
          dir)    default="$d_dir" ;;
          git)    default="$d_git" ;;
          branch) default="$d_branch" ;;
          label)  default="$d_label" ;;
        esac
        state="$(printf '%s' "$cfg" | jq -r --arg k "$key" '
          def clean($v): ($v|type) == "string" and (($v|explode|map(select(. < 32))|length) == 0);
          def pick($v; $d): if clean($v) and ($v|length) > 0 and ($v|length) < 20
                            then $v else $d end;
          def ifnull($x; $d): if $x == null then $d else $x end;
          ((ifnull(.statusline; {})) | ifnull(.colors; {}) | .[$k]) as $v
          | if $v == null then "skip"
            elif ($v|type) == "string" and ($v|length) > 0 and ($v|length) < 20
                 and (clean($v) | not) then "invisible"
            elif pick($v; null) == null then "bad"
            else "ok" end
        ' 2>/dev/null)"
        case "$state" in
          ok) ;;
          invisible)
            printf 'statusline.colors.%s: must not contain an invisible character such as a tab; using %s\n' \
              "$key" "$default"
            continue
            ;;
          bad)
            printf 'statusline.colors.%s: not a usable colour name; using %s\n' "$key" "$default"
            continue
            ;;
          *) continue ;;
        esac
        [ "$colors_ok" = noplain ] && continue
        name="$(printf '%s' "$cfg" | jq -r --arg k "$key" '.statusline.colors[$k]' 2>/dev/null)"
        [ -n "$(cp_sl_code "$name")" ] && continue
        # The raw name is what cp_sl_code has to judge; the name the message
        # carries goes through safe() like every other name a configuration
        # file supplied. This is the one report whose value the resolver kept,
        # so it is also the one where a DEL or a bidi override -- both of them
        # past clean(), which only looks below 32 -- would otherwise reach the
        # output as itself.
        printf 'statusline.colors.%s: unknown colour %s; rendering it plain\n' "$key" \
          "$(printf '%s' "$cfg" | jq -r --arg k "$key" "$esc_def"'
               safe(.statusline.colors[$k])' 2>/dev/null)"
      done
      ;;
  esac
}

# cp_sl_code <name> -> an SGR parameter for a configured colour name, or
# nothing when the name is not one cprof knows, in which case the caller
# renders the segment plain rather than dropping it. `dim` is handled here
# because it is an attribute rather than a colour, so cp_color_code, which
# owns the palette `cprof color` documents, does not carry it.
cp_sl_code() {
  case "${1:-}" in
    dim) printf '2\n' ;;
    *)   cp_color_code "${1:-}" ;;
  esac
}

# cp_sl_wants <layout> <segment> -> 0 when the layout names that segment,
# anywhere in any line. A helper rather than a pattern match on the layout
# string, which would have to special-case a segment at the start or end of
# a line.
cp_sl_wants() {
  local seg
  for seg in $(printf '%s' "${1:-}" | tr ';' ' '); do
    [ "$seg" = "${2:-}" ] && return 0
  done
  return 1
}

# cp_sl_assemble <layout> <sep>: prints one output line per configured line,
# skipping a line whose segments all came back empty. Each segment's
# rendered text comes from the shell variable CP_SL_<segment>, set by
# cp_cmd_statusline before calling this. `git` attaches to `dir` with a
# single space so that a directory and its branch read as one thing; every
# other adjacency takes the separator. A segment named more than once in a
# line renders every time it appears -- the layout is taken literally, not
# deduplicated.
cp_sl_assemble() {
  local layout="${1:-}" sep="${2:-}" line seg text out prev
  # A trailing newline before tr, not just the ';' separators, or the last
  # configured line reaches `read` as a no-newline EOF read: `read` returns
  # non-zero for it, and `while read` treats that as the end of input, so
  # the final line of the layout is silently dropped.
  printf '%s\n' "$layout" | tr ';' '\n' | while IFS= read -r line; do
    out=''; prev=''
    for seg in $line; do
      eval "text=\${CP_SL_$seg:-}"
      [ -n "$text" ] || continue
      if [ -z "$out" ]; then
        out="$text"
      elif [ "$seg" = git ] && [ "$prev" = dir ]; then
        out="$out $text"
      else
        out="$out$sep$text"
      fi
      prev="$seg"
    done
    [ -n "$out" ] && printf '%s\n' "$out"
  done
}

# cp_cmd_statusline [--stdin]: the whole statusline, laid out the way the
# resolved configuration says.
#
# Each segment renders into its own shell variable -- CP_SL_badge,
# CP_SL_model, CP_SL_dir, CP_SL_git, CP_SL_context, CP_SL_usage -- holding
# only that segment's own text, with no separator. cp_sl_assemble then walks
# the configured layout and joins what is there. A segment the layout does
# not name is never rendered at all, so an unconfigured git segment runs no
# git commands, and a segment with nothing to say leaves no stray separator.
#
# Colour is decided here the way the segment decides it, on NO_COLOR alone,
# rather than through cp_color_enabled: a statusline's stdout is a pipe, so
# the `[ -t 1 ]` test in that helper would turn colour off in the one place
# it is always wanted.
cp_cmd_statusline() {
  local read_stdin=0 payload='' cfg name colour code text sep=''
  local meta model dir dir_label git_fields branch dirty
  local u_pct u_bar u_code u_reset c_pct c_bar c_code
  local colour_on=1 config layout bar_cfg b_fill b_empty b_width
  local thresh_cfg th_warn th_crit
  local colors_cfg col_model col_dir col_git col_branch col_label
  local label_open='' label_close=''
  # These are read by cp_sl_assemble through `eval` on a name built from the
  # layout's own segment names, which is why nothing in this function appears
  # to use them.
  local CP_SL_badge='' CP_SL_model='' CP_SL_dir='' CP_SL_git=''
  local CP_SL_context='' CP_SL_usage=''

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --stdin) read_stdin=1; shift ;;
      *)       cp_warn "statusline: unknown flag $1"; return 2 ;;
    esac
  done
  [ -z "${NO_COLOR+set}" ] || colour_on=0
  [ "$read_stdin" -eq 1 ] && [ ! -t 0 ] && payload="$(cat 2>/dev/null)"

  cfg="$(cp_config_read 2>/dev/null)" || cfg=''
  name="$(CPROF_COLOR=never cp_cmd_status 2>/dev/null)" || return 0
  case "$name" in ''|stock) return 0 ;; esac

  config="$(cp_sl_config "$cfg")"
  layout="$(printf '%s' "$config" | sed -n '1p')"
  bar_cfg="$(printf '%s' "$config" | sed -n '2p')"
  b_fill="$(printf '%s' "$bar_cfg" | cut -f1)"
  b_empty="$(printf '%s' "$bar_cfg" | cut -f2)"
  b_width="$(printf '%s' "$bar_cfg" | cut -f3)"
  thresh_cfg="$(printf '%s' "$config" | sed -n '3p')"
  th_warn="$(printf '%s' "$thresh_cfg" | cut -f1)"
  th_crit="$(printf '%s' "$thresh_cfg" | cut -f2)"
  colors_cfg="$(printf '%s' "$config" | sed -n '4p')"
  col_model="$(cp_sl_code "$(printf '%s' "$colors_cfg" | cut -f1)" 2>/dev/null)"
  col_dir="$(cp_sl_code "$(printf '%s' "$colors_cfg" | cut -f2)" 2>/dev/null)"
  col_git="$(cp_sl_code "$(printf '%s' "$colors_cfg" | cut -f3)" 2>/dev/null)"
  col_branch="$(cp_sl_code "$(printf '%s' "$colors_cfg" | cut -f4)" 2>/dev/null)"
  col_label="$(cp_sl_code "$(printf '%s' "$colors_cfg" | cut -f5)" 2>/dev/null)"

  if [ "$colour_on" -eq 1 ] && [ -n "$col_label" ]; then
    label_open="$(printf '\033[%sm' "$col_label")"
    label_close="$(printf '\033[0m')"
  fi

  if [ "$colour_on" -eq 0 ]; then
    sep=' │ '
  elif [ -n "$col_label" ]; then
    sep="$(printf '\033[%sm │ \033[0m' "$col_label")"
  else
    sep=' │ '
  fi

  if cp_sl_wants "$layout" badge; then
    colour="$(cp_color_for "$cfg" "$name" 2>/dev/null)"
    code="$(cp_color_code "$colour" 2>/dev/null)"
    # The same decision `cprof color --render` answers for the one-line
    # segment, from the same helper: see cp_color_text_flag for why jq's `//`
    # cannot be used on it.
    text="$(cp_color_text_flag "$cfg")"
    if [ "$colour_on" -eq 0 ]; then
      CP_SL_badge="⚑ $name"
    elif [ -z "$code" ]; then
      CP_SL_badge="$(printf '\033[2m⚑ %s\033[0m' "$name")"
    elif [ "$text" = 'on' ]; then
      CP_SL_badge="$(printf '\033[%sm⚑ %s\033[0m' "$code" "$name")"
    else
      # shellcheck disable=SC2034 # read by cp_sl_assemble via eval
      CP_SL_badge="$(printf '\033[%sm⚑\033[0m \033[2m%s\033[0m' "$code" "$name")"
    fi
  fi

  if [ -n "$payload" ]; then
    meta="$(printf '%s' "$payload" | cp_sl_meta_fields)"
    model="$(printf '%s' "$meta" | cut -f1)"
    dir="$(printf '%s' "$meta" | cut -f2)"
  fi

  if cp_sl_wants "$layout" model && [ -n "${model:-}" ]; then
    if [ "$colour_on" -eq 1 ] && [ -n "$col_model" ]; then
      CP_SL_model="$(printf '\033[%sm[%s]\033[0m' "$col_model" "$model")"
    else
      # shellcheck disable=SC2034 # read by cp_sl_assemble via eval
      CP_SL_model="[$model]"
    fi
  fi

  if cp_sl_wants "$layout" dir; then
    dir_label="$(cp_sl_dir_label "${dir:-}")"
    if [ -n "$dir_label" ]; then
      if [ "$colour_on" -eq 1 ] && [ -n "$col_dir" ]; then
        CP_SL_dir="$(printf '\033[%sm%s\033[0m' "$col_dir" "$dir_label")"
      else
        # shellcheck disable=SC2034 # read by cp_sl_assemble via eval
        CP_SL_dir="$dir_label"
      fi
    fi
  fi

  if cp_sl_wants "$layout" git; then
    git_fields="$(cp_sl_git_fields "${dir:-}")"
    if [ -n "$git_fields" ]; then
      branch="$(printf '%s' "$git_fields" | cut -f1)"
      dirty="$(printf '%s' "$git_fields" | cut -f2)"
      if [ "$colour_on" -eq 1 ] && [ -n "$col_git" ] && [ -n "$col_branch" ]; then
        CP_SL_git="$(printf '\033[%smgit:(\033[0m\033[%sm%s%s\033[0m\033[%sm)\033[0m' \
          "$col_git" "$col_branch" "$branch" "$dirty" "$col_git")"
      else
        # shellcheck disable=SC2034 # read by cp_sl_assemble via eval
        CP_SL_git="git:($branch$dirty)"
      fi
    fi
  fi

  # The bars come from the same renderer the one-line segment uses, so the
  # two entry points can never disagree about a percentage or a colour. Only
  # spent when the layout actually asks for one of the two.
  if cp_sl_wants "$layout" context || cp_sl_wants "$layout" usage; then
    if [ -n "$payload" ]; then
      u_pct="$(printf '%s' "$payload" | cp_usage_render_fields "$name" --stdin)"
    else
      u_pct="$(cp_usage_render_fields "$name" </dev/null)"
    fi
    c_pct="$(printf '%s' "$u_pct" | cut -f5)"
    u_reset="$(printf '%s' "$u_pct" | cut -f4)"
    u_pct="$(printf '%s' "$u_pct" | cut -f1)"
    # The bars are redrawn here from the percentages with the configured
    # glyphs and width, rather than taking the pre-drawn ten-cell bar out of
    # cp_usage_render_fields, so the statusline can never disagree with the
    # tables about what a percentage looks like.
    u_bar="$(cp_usage_bar "$u_pct" "$b_fill" "$b_empty" "$b_width")"
    c_bar="$(cp_usage_bar "$c_pct" "$b_fill" "$b_empty" "$b_width")"
    # The colours are likewise derived here, from each bar's own percentage
    # and the configured thresholds, rather than taking cp_usage_render_fields'
    # SGR codes -- those are computed against the hardcoded 70/90 for the
    # helper's own callers, so reading them here would make a configured
    # threshold change nothing on screen.
    u_code="$(cp_color_code "$(cp_usage_severity_colour "$u_pct" "$th_warn" "$th_crit" 2>/dev/null)" 2>/dev/null)"
    c_code="$(cp_color_code "$(cp_usage_severity_colour "$c_pct" "$th_warn" "$th_crit" 2>/dev/null)" 2>/dev/null)"

    if cp_sl_wants "$layout" context && [ -n "$c_pct" ]; then
      if [ "$colour_on" -eq 1 ]; then
        CP_SL_context="$(printf '%sContext%s %s \033[%sm%s%%\033[0m' \
          "$label_open" "$label_close" "$(cp_sl_bar "$c_bar" "$c_code" "$b_empty")" "$c_code" "$c_pct")"
      else
        # shellcheck disable=SC2034 # read by cp_sl_assemble via eval
        CP_SL_context="Context $c_bar $c_pct%"
      fi
    fi
    if cp_sl_wants "$layout" usage && [ -n "$u_pct" ]; then
      if [ "$colour_on" -eq 1 ]; then
        CP_SL_usage="$(printf '%sUsage%s %s \033[%sm%s%%\033[0m' \
          "$label_open" "$label_close" "$(cp_sl_bar "$u_bar" "$u_code" "$b_empty")" "$u_code" "$u_pct")"
        [ -n "$u_reset" ] && CP_SL_usage="$CP_SL_usage$(printf ' %s(resets in %s)%s' "$label_open" "$u_reset" "$label_close")"
      else
        CP_SL_usage="Usage $u_bar $u_pct%"
        [ -n "$u_reset" ] && CP_SL_usage="$CP_SL_usage (resets in $u_reset)"
      fi
    fi
  fi

  cp_sl_assemble "$layout" "$sep"
  return 0
}
