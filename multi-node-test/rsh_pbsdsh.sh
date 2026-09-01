#!/bin/bash
# Open MPI rsh plm agent -> pbsdsh bridge for PBS Pro.
#
# GAAS Open MPI is built without the TM plm component, and inter-node ssh/rsh
# is unavailable, so we use PBS Pro's native pbsdsh (task-manager remote shell)
# as the cross-node transport.
#
# Open MPI invokes plm_rsh_agent as:
#     agent <hostname> <shell-cmd> [extra args ...]
# where <shell-cmd> is an env-prefixed "orted ..." command line meant to be
# evaluated by a shell on the remote host.
#
# This script maps <hostname> to its 0-based VNODE index in the PBS
# allocation (i.e. its position in the de-duplicated PBS_NODEFILE, since
# pbsdsh -n indexes vnodes, not individual rank lines) and launches the
# reconstructed command there via pbsdsh -n <index> -o.

set -u

HOST="$1"; shift

if [ -z "${PBS_NODEFILE:-}" ] || [ ! -r "${PBS_NODEFILE:-}" ]; then
  echo "rsh_pbsdsh: PBS_NODEFILE not set or unreadable" >&2
  exit 1
fi

# De-duplicated index: PBS_NODEFILE lists one line per MPI rank (mpiprocs
# copies per node). pbsdsh -n indexes VNODES, so skip repeated lines.
idx=$(awk -v h="$HOST" '
  { gsub(/\r$/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); if ($0 == "") next }
  { if ($0 == h && !done) { print n; done = 1; exit } }
  { if (!($0 in seen)) { seen[$0] = 1; n++ } }
' "$PBS_NODEFILE")

if [ -z "$idx" ]; then
  echo "rsh_pbsdsh: host '$HOST' not found in PBS_NODEFILE" >&2
  exit 1
fi

cmd=""
for a in "$@"; do
  cmd="${cmd} ${a}"
done

# Run through sh so the env-prefix and embedded quoting in the remote command
# are interpreted correctly. Use "-o" (no obit wait): pbsdsh returns once the
# task is spawned, leaving orted running under pbs_mom. mpirun then waits for
# orted to connect back over TCP. (Blocking without "-o" can deadlock in some
# ORTE rsh-plm configurations.)
exec /opt/pbs/bin/pbsdsh -n "$idx" -o -- sh -c "$cmd"