# Sourced by demo.tape before recording. Sandboxes HOME so the prompt
# shows tidy ~/dev paths and nothing touches a real config.
DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HOME="${TMPDIR:-/tmp}/cprof-demo-home"
mkdir -p "$HOME/dev/acme/api" "$HOME/dev/side-project"
export PATH="$DEMO_ROOT/bin:$PATH"
PS1='$ '
cd "$HOME"
