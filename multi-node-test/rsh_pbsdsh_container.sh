#!/bin/bash
# Open MPI rsh plm agent -> pbsdsh -> apptainer bridge (approach 1).
#
# This runs as plm_rsh_agent for the *container's own* mpirun, so that the
# remote orted is launched INSIDE the container (consistent MPI end-to-end:
# container mpirun + container orted + container app).
#
# Open MPI invokes plm_rsh_agent as:
#     agent <hostname> <shell-cmd...>
# where <shell-cmd...> is an env-prefixed "orted ..." command line meant for a
# shell. We map <hostname> to its 0-based vnode index in the de-duplicated
# PBS_NODEFILE, then launch that reconstructed command on the remote node,
# wrapped in "apptainer exec" so it resolves to the container's orted. The
# remote apptainer needs squashfuse/gocryptfs paths to mount the encrypted SIF.

set -u

HOST="$1"; shift

if [ -z "${PBS_NODEFILE:-}" ] || [ ! -r "${PBS_NODEFILE:-}" ]; then
  echo "rsh_pbsdsh_container: PBS_NODEFILE not set or unreadable" >&2
  exit 1
fi

idx=$(awk -v h="$HOST" '
  { gsub(/\r$/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); if ($0 == "") next }
  { if ($0 == h && !done) { print n; done = 1; exit } }
  { if (!($0 in seen)) { seen[$0] = 1; n++ } }
' "$PBS_NODEFILE")

if [ -z "$idx" ]; then
  echo "rsh_pbsdsh_container: host '$HOST' not found in PBS_NODEFILE" >&2
  exit 1
fi

cmd=""
for a in "$@"; do
  cmd="${cmd} ${a}"
done

SIF="/home/pham0094/hpl_hpcg_hplmxp_container/hpc-benchmarks_26.02.sif"
APPT="/usr/local/apptainer/1.4.1/bin/apptainer"
PRE="export PATH=/usr/local/apptainer/1.4.1/bin:/usr/local/squashfuse/0.5.2/bin:/usr/local/gocryptfs/2.5.0/bin:\$PATH; export LD_LIBRARY_PATH=/usr/local/squashfuse/0.5.2/lib:\$LD_LIBRARY_PATH;"

echo "rsh_pbsdsh_container: HOST=$HOST idx=$idx cmd=[$cmd]" >&2

# Run the env-prefixed orted command *inside* the container via apptainer.
# The command is single-quoted (it contains no single quotes itself) so its
# embedded double-quotes / parentheses survive the two shell layers intact.
exec /opt/pbs/bin/pbsdsh -n "$idx" -o -- sh -c \
  "${PRE} ${APPT} exec --nv ${SIF} bash -c '${cmd}'"