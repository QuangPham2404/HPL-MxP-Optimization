# GAAS Multi-Node Launch Setup

This document captures what is actually broken/awkward about running
multi-node MPI jobs on the GAAS cluster, and the exact fixes that have been
**tested and confirmed to work** (nothing here is speculative).

It applies to any multi-node MPI job launched from an Apptainer container
on GAAS (e.g. HPL-MxP, PyTorch DDP). Everything below was validated with a
2-node and 3-node GPU scaling sweep (`select=2:ngpus=G`, `select=3:ngpus=G` for
`G = 1, 2, 4`).

---

## 1. Why stock multi-node launch fails on GAAS

### 1.1 Open MPI has no TM (task-manager) PLM component

Every Open MPI on the cluster — host NVHPC, the HPC-X bundled with NVHPC, and
the Open MPI inside the NVIDIA benchmark container — is built with only these
launcher components:

```
MCA plm: isolated, rsh, slurm     (NO "tm")
MCA ras: simulator, slurm         (NO "tm", NO "pbs"/"torque")
```

`ompi_info` confirms this. The `tm` component is what Open MPI normally uses on
Torque/PBS clusters to discover the allocation and `tm_spawn` daemons onto the
other nodes. Without it, `mpirun` cannot auto-detect the PBS allocation, so a
naive `mpirun -np 8 ...` has no idea there are other nodes or how to reach them.

### 1.2 There is no `pbs_tmrsh`, and no `rsh`

The usual workaround for "no TM component" is to point `plm_rsh_agent` at
`pbs_tmrsh` (a Torque/OpenPBS helper). **GAAS is PBS Pro (Altair), not Torque,
so `pbs_tmrsh` does not exist anywhere on the system.** There is also no
`rsh`/`/usr/bin/rsh` binary, and no `pbs_tmrsh`.

`pbs_remsh` (PBS Pro's equivalent) exists, but it internally execs
`${PBS_RSHCOMMAND:-rsh}`, and `rsh` is absent, so it just fails with
`rsh: command not found`.

### 1.3 Inter-node SSH is blocked

Passwordless `ssh` to a compute node authenticates successfully, but then any
non-interactive `ssh <node> <cmd>` is **signal-killed** (SSH reports
`exit-signal`, exit 255) — including from *inside* a running job. So
`plm_rsh_agent=ssh` does not work as a fallback either.

### 1.4 Container `mpirun` cannot drive the cross-node spawn

The natural thing — run `mpirun` *inside* the container — fails for a different
reason: the container's `mpirun` needs to launch the container's `orted` on the
remote node, but any `plm_rsh_agent`/`pbsdsh` bridge launches the command on the
remote node's **host** (not inside the container), so the container `orted`
path never resolves there.

### 1.5 A 4-GPU chunk does not imply a distinct node

`#PBS -l select=2:ngpus=4` alone lets the scheduler pack both 4-GPU chunks onto
a single 8-GPU node (GAAS nodes expose 8 GPUs). The resulting `$PBS_NODEFILE`
lists the same host twice. Force node separation with `place=scatter`.

### 1.6 The container cannot see PBS files or mount the SIF unaided

Inside the container, `$PBS_NODEFILE` points at `/var/spool/pbs/aux/...`, which
is **not** mounted in, so the hostfile is unreadable. And the encrypted SIF
must be mounted via `squashfuse` + `gocryptfs`; those module-provided tools only
exist on the mother-superior shell unless explicitly propagated to remote ranks.

---

## 2. The fixes (all validated)

### 2.1 `place=scatter` forces separate nodes

```bash
#PBS -l select=2:ngpus=4
#PBS -l place=scatter
```

Result: `$PBS_NODEFILE` lists two distinct hosts.

### 2.2 A `pbsdsh` bridge as `plm_rsh_agent`

The only cross-node transport that works on GAAS is **`pbsdsh`** (PBS Pro's
native task-manager remote shell — it uses TM directly, no SSH/rsh). We wrap it
in `rsh_pbsdsh.sh` and set it as `plm_rsh_agent`.

Open MPI invokes `plm_rsh_agent` as:

```
agent <hostname> <shell-cmd...>
```

where `<shell-cmd...>` is an env-prefixed `orted ...` line meant to be run by a
shell on the remote host. The wrapper maps `<hostname>` to its **vnode index**
(its position in the *de-duplicated* `$PBS_NODEFILE`) and runs the command there:

```bash
#!/bin/bash
HOST="$1"; shift
# de-duplicated (vnode) index, since pbsdsh -n indexes vnodes not rank lines
idx=$(awk -v h="$HOST" '
  { gsub(/\r$/,""); sub(/^[ \t]+/,""); sub(/[ \t]+$/,""); if ($0=="") next }
  { if ($0==h && !done) { print n; done=1; exit } }
  { if (!($0 in seen)) { seen[$0]=1; n++ } }
' "$PBS_NODEFILE")
[ -z "$idx" ] && { echo "host $HOST not in PBS_NODEFILE" >&2; exit 1; }
cmd=""; for a in "$@"; do cmd="$cmd $a"; done
exec /opt/pbs/bin/pbsdsh -n "$idx" -o -- sh -c "$cmd"
```

This is the key file: `multi-node-test/rsh_pbsdsh.sh`.

### 2.3 Host `mpirun` drives; the container runs per rank — **SUPERSEDED**

> **Deprecated.** This host-`mpirun` form validated only rank *spawn*, not MPI
> communication. It hung in `MPI_Init` for real HPL runs because the host
> `mpirun` (host HPC-X 2.25.1 OpenMPI) drove a container MPI app (container
> HPC-X at `/opt/hpcx`) — same version, different build, so the cross-node
> ORTE/PMIx handshake never completed. Use **Approach 1** instead (see below).

Do **not** run `mpirun` inside the container for multi-node. Instead, use the
**host** HPC-X `mpirun` and make each MPI rank run `apptainer exec --nv <sif>`:

```bash
mpirun ... apptainer exec --nv "$SIF" /workspace/hpl-mxp.sh ...
```

(This form was superseded because it could not complete cross-node MPI.)

### 2.4 Propagate module env with `-x PATH -x LD_LIBRARY_PATH`

`squashfuse`/`gocryptfs` (needed to mount the encrypted SIF) are added to
`PATH`/`LD_LIBRARY_PATH` by `module load` on the mother-superior only. Without
propagation, remote ranks fail with `apptainer: transport endpoint is not
connected`. Pass them through:

```bash
-x PATH -x LD_LIBRARY_PATH
```

### 2.5 De-duplicated hostfile with explicit `slots=G` (not `ppr:N:node`)

`--map-by ppr:G:node` is unreliable here (randomly produces "No nodes
available" / "all nodes filled", and mis-maps ranks for some `G`). Build a
hostfile that names each node once with an explicit slot count, and use default
slot mapping:

```bash
awk -v g="$G" '{ sub(/\r$/,""); if (!seen[$0]++) print $0 " slots=" g }' \
  "$PBS_NODEFILE" > hostfile
mpirun -np $((NNODES*G)) --hostfile hostfile ...
```

### 2.6 Reliable daemon spawn flags

```bash
--mca plm_rsh_agent "$PWD/rsh_pbsdsh.sh" \
--mca plm_rsh_no_tree_spawn 1 \
--mca plm_rsh_num_concurrent 1 \
--mca routed direct
```

`no_tree_spawn` avoids tree-based daemon spawning (which otherwise wired up
stale/broad node names), `routed direct` gives direct daemon-to-HNP routing,
and `num_concurrent 1` serializes orted launches.

### 2.7 Submit jobs sequentially (not many at once)

Submitting several multi-node jobs back-to-back in the same instant triggered
intermittent `No nodes are available` / `All nodes ... already filled` races
and occasional hangs. Submitting them **one at a time** (wait for each to
finish) is reliable. See `run_scaling_sweep_seq.sh`.

### 2.8 Do not set `mpiprocs` in the select spec

`select=N:ngpus=G:mpiprocs=G` makes `$PBS_NODEFILE` include `G` lines per node,
which changes `pbsdsh -n` vnode indexing and breaks rank mapping. Keep it to
`select=N:ngpus=G` and derive the rank count yourself (`NPROCS = NNODES * G`).

---

## 3. Minimal multi-node script walkthrough

```bash
#!/bin/bash
#PBS -N HPL_MXP_MULTINODE
#PBS -q gpu_as
#PBS -P hpc_admin
#PBS -l select=2:ngpus=4            # N nodes x G GPUs per node (no mpiprocs)
#PBS -l place=scatter               # force distinct physical nodes
#PBS -l walltime=00:45:00
#PBS -o outputs/run.o
#PBS -e outputs/run.e

set -euo pipefail
cd "$PBS_O_WORKDIR"

module purge
module load apptainer/1.4.1
module load nvhpc/26.3
module load squashfuse/0.5.2
module load gocryptfs/2.5.0
chmod +x "$PWD/rsh_pbsdsh.sh"

SIF="/home/pham0094/hpl_hpcg_hplmxp_container/hpc-benchmarks_26.02.sif"
RSH_AGENT="$PWD/rsh_pbsdsh.sh"

NNODES=$(sort -u "$PBS_NODEFILE" | wc -l)
G=4                                   # GPUs (and ranks) per node
NPROCS=$((NNODES * G))

# De-duplicated hostfile with explicit slots.
awk -v g="$G" '{ sub(/\r$/,""); if (!seen[$0]++) print $0 " slots=" g }' \
  "$PBS_NODEFILE" > "$PWD/hostfile"

# Host mpirun drives the cross-node spawn; each rank execs the container.
mpirun -np "$NPROCS" \
  --hostfile "$PWD/hostfile" \
  --mca plm_rsh_agent "$RSH_AGENT" \
  --mca plm_rsh_no_tree_spawn 1 \
  --mca plm_rsh_num_concurrent 1 \
  --mca routed direct \
  -x PATH -x LD_LIBRARY_PATH \
  --bind-to none \
  apptainer exec --nv "$SIF" /workspace/hpl-mxp.sh \
    --gpu-affinity 0:1:2:3
```

### Scaling

Change `-l select` and `G` together. Validated combinations (nodes × GPUs/node):

| nodes × GPUs | select | ranks |
|---|---|---|
| 2 × 1 | `select=2:ngpus=1` | 2 |
| 2 × 2 | `select=2:ngpus=2` | 4 |
| 2 × 4 | `select=2:ngpus=4` | 8 |
| 3 × 1 | `select=3:ngpus=1` | 3 |
| 3 × 2 | `select=3:ngpus=2` | 6 |
| 3 × 4 | `select=3:ngpus=4` | 12 |

Each node ends up with `G` ranks whose `OMPI_COMM_WORLD_LOCAL_RANK` runs 0..G-1,
which is what `--gpu-affinity 0:…:G-1` expects.

For `N` nodes, set `select=N:ngpus=G` and keep `G` (per-node GPUs) fixed; the
script derives `NPROCS = N * G` and `hostfile` from `$PBS_NODEFILE` automatically.

### Per-rank GPU binding

The GPU mapping is driven by the *local* rank, not the global rank. In a
per-rank launch you get (for 2×4):

```
rank 0..3 -> node0, localrank 0..3
rank 4..7 -> node1, localrank 0..3
```

`nvidia-smi -L` inside the container enumerates each node's GPUs as local
indices 0..G-1, so `--gpu-affinity 0:1:2:3` maps localrank -> local GPU correctly
on every node.