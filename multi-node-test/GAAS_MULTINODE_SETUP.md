# GAAS Multi-Node Launch Setup

This document logs what is broken or awkward about launching multi-node MPI
jobs on the GAAS cluster, and the exact fixes that were **tested and confirmed
to work** (nothing here is speculative). It is written for future debugging of
the same errors and as a template for other multi-node workloads.

Two layers are covered:

1. **General multi-node job launch on GAAS** — cluster-level blockers that affect
   *any* multi-node MPI job (native or containerized), and their fixes.
2. **Multi-node setup for HPL-MxP** — the benchmark-specific blockers layered on
   top of the general ones, their fixes, and the validated scaling results.

## Environment snapshot

| item | value |
|---|---|
| Scheduler | PBS Pro (Altair), queue `gpu_as`, project `hpc_admin` |
| Compute nodes | NVIDIA H200 SXM 141 GB, 8 GPUs / node |
| Container runtime | Apptainer 1.4.1 |
| Host MPI stack | NVHPC 26.3 → HPC-X 2.25.1 (OpenMPI 4.1.9a1) |
| Benchmark container | `hpc-benchmarks_26.02.sif` (NVIDIA HPC Benchmarks v26.02), bundles its own HPC-X OpenMPI 4.1.9a1 at `/opt/hpcx`, MPI binaries at `/usr/local/mpi/bin` |
| Encrypted SIF mount | `squashfuse/0.5.2` + `gocryptfs/2.5.0` (module-provided) |

---

# 1. General multi-node job launch on GAAS

## 1.1 Blockers/errors and their fixes

### Blocker 1 — Open MPI has no TM (task-manager) PLM component

Every Open MPI build on the cluster (host NVHPC, the HPC-X bundled with NVHPC,
and the Open MPI inside the container) is built **without** the `tm` launcher
component. This is the component Open MPI normally uses on Torque/PBS clusters
to discover the allocation and `tm_spawn` daemons onto the other nodes.

Verification artifact (`ompi_info`):

```
MCA plm: isolated, rsh, slurm     (NO "tm")
MCA ras: simulator, slurm         (NO "tm", NO "pbs"/"torque")
```

**Consequence:** a naive `mpirun -np N ...` cannot auto-detect the PBS
allocation. It has no idea there are other nodes, let alone how to reach them —
so it silently runs everything on the local node only.

**Fix:** drive the launcher explicitly with a `--hostfile` and an
`plm_rsh_agent` bridge that performs the cross-node spawn (see Blocker 4).

### Blocker 2 — No `pbs_tmrsh`, no `rsh`, and `pbs_remsh` is broken

The usual workaround for "no TM component" is to point `plm_rsh_agent` at
`pbs_tmrsh` (a Torque/OpenPBS helper). **GAAS is PBS Pro (Altair), not Torque,**
so `pbs_tmrsh` does not exist anywhere on the system. There is also no
`rsh`/`/usr/bin/rsh` binary.

`pbs_remsh` (PBS Pro's own equivalent) *does* exist, but it internally execs
`${PBS_RSHCOMMAND:-rsh}`, and since `rsh` is absent it fails immediately:

```
rsh: command not found
```

**Fix:** none available for these tools — they are dead ends. See the `pbsdsh`
route in Blocker 4.

### Blocker 3 — Inter-node SSH is blocked

Passwordless `ssh` to a compute node authenticates successfully, but any
non-interactive `ssh <node> <cmd>` is **signal-killed** (SSH reports an
`exit-signal`, exit code 255) — including when run from *inside* a live job. So
`plm_rsh_agent=ssh` does not work as a fallback.

**Fix:** do not use SSH as the spawn transport.

### Blocker 4 (the fix) — `pbsdsh` is the only working cross-node transport

The only cross-node spawn mechanism that works on GAAS is **`pbsdsh`**, PBS Pro's
native task-manager remote shell. It talks to `pbs_mom` directly (real TM), no
SSH/rsh involved. Open MPI's `plm_rsh` component invokes its agent as:

```
agent <hostname> <shell-cmd...>
```

where `<shell-cmd...>` is an env-prefixed `orted ...` line meant for a shell on
the remote host. A bridge script maps `<hostname>` → its **vnode index** (its
position in the *de-duplicated* `$PBS_NODEFILE`) and launches the reconstructed
command there via `pbsdsh -n <idx> -o`.

`multi-node-test/rsh_pbsdsh.sh` (the general bridge):

```bash
#!/bin/bash
# Open MPI rsh plm agent -> pbsdsh bridge for PBS Pro.
# GAAS Open MPI has no TM plm component and no ssh/rsh, so use PBS Pro's
# pbsdsh as the cross-node transport.
set -u
HOST="$1"; shift
[ -r "${PBS_NODEFILE:-}" ] || { echo "PBS_NODEFILE unreadable" >&2; exit 1; }

# pbsdsh -n indexes VNODES, not rank lines, so de-duplicate PBS_NODEFILE.
idx=$(awk -v h="$HOST" '
  { gsub(/\r$/,""); sub(/^[ \t]+/,""); sub(/[ \t]+$/,""); if ($0=="") next }
  { if ($0==h && !done) { print n; done=1; exit } }
  { if (!($0 in seen)) { seen[$0]=1; n++ } }
' "$PBS_NODEFILE")
[ -z "$idx" ] && { echo "host $HOST not in PBS_NODEFILE" >&2; exit 1; }

cmd=""; for a in "$@"; do cmd="$cmd $a"; done
# "-o" = no obit wait: return once orted is spawned (leaves it under pbs_mom).
exec /opt/pbs/bin/pbsdsh -n "$idx" -o -- sh -c "$cmd"
```

### Blocker 5 — `select=N:ngpus=G` does not imply distinct nodes

`#PBS -l select=2:ngpus=4` alone lets the scheduler pack both 4-GPU chunks onto a
single 8-GPU node, producing a `$PBS_NODEFILE` that lists the same host twice.

**Fix:** force physical separation with `place=scatter`:

```bash
#PBS -l select=2:ngpus=4
#PBS -l place=scatter
```

### Blocker 6 — do not set `mpiprocs` in the `select` spec

`select=N:ngpus=G:mpiprocs=G` makes `$PBS_NODEFILE` list `G` lines per node. This
changes how `pbsdsh -n` indexes vnodes and breaks the bridge's rank mapping.

**Fix:** keep it to `select=N:ngpus=G` and derive the rank count yourself
(`NPROCS = NNODES * G`).

### Blocker 7 — concurrent multi-node submissions race

Submitting several multi-node jobs back-to-back in the same instant triggers
intermittent `No nodes are available` / `All nodes ... already filled` races and
occasional hangs.

**Fix:** submit one job at a time and wait for completion before the next.

### Blocker 8 — `--map-by ppr:G:node` is unreliable

`ppr:G:node` mapping randomly produces "No nodes available" / "all nodes filled"
and mis-maps ranks for some `G`.

**Fix:** build a de-duplicated hostfile with an explicit slot count per node and
use the default slot mapping:

```bash
awk -v g="$G" '{ sub(/\r$/,""); if (!seen[$0]++) print $0 " slots=" g }' \
  "$PBS_NODEFILE" > hostfile
mpirun -np $((NNODES * G)) --hostfile hostfile ...
```

## 1.2 Working launch excerpt (general / native MPI)

This is the canonical GAAS pattern for a native (non-container) multi-node MPI
job: host `mpirun`, host `orted`, and a host-side app all use the same host
OpenMPI build, launched through the `pbsdsh` bridge.

```bash
#!/bin/bash
#PBS -N GEN_MULTINODE
#PBS -q gpu_as
#PBS -P hpc_admin
#PBS -l select=2:ngpus=4            # N nodes x G GPUs (no mpiprocs)
#PBS -l place=scatter               # force distinct physical nodes
#PBS -l walltime=00:45:00

set -euo pipefail
cd "$PBS_O_WORKDIR"
chmod +x "$PWD/rsh_pbsdsh.sh"

# G ranks per node (one per GPU in this example).
NNODES=$(sort -u "$PBS_NODEFILE" | wc -l)
G=4
NPROCS=$((NNODES * G))

# De-duplicated hostfile with explicit per-node slot count (see Blocker 8).
awk -v g="$G" '{ sub(/\r$/,""); if (!seen[$0]++) print $0 " slots=" g }' \
  "$PBS_NODEFILE" > "$PWD/hostfile"

# Host mpirun drives the cross-node spawn through the pbsdsh bridge.
mpirun -np "$NPROCS" \
  --hostfile "$PWD/hostfile" \
  --mca plm_rsh_agent "$PWD/rsh_pbsdsh.sh" \
  --mca plm_rsh_no_tree_spawn 1 \
  --mca plm_rsh_num_concurrent 1 \
  --mca routed direct \
  --bind-to none \
  /path/to/host_mpi_app [args...]
```

The fixed daemon-spawn flags are important:

- `plm_rsh_no_tree_spawn 1` — avoids tree-based daemon spawning (which wired up
  stale/broad node names).
- `plm_rsh_num_concurrent 1` — serializes `orted` launches.
- `routed direct` — direct daemon-to-HNP routing.

> **Important caveat.** The host-`mpirun` form above works for a *native* app whose
> MPI build matches the launcher. For a **containerized** app, this form only
> validates rank *spawn*; it cannot complete cross-node MPI communication (see
> Section 2, Blocker A).

---

# 2. Multi-node setup for HPL-MxP

HPL-MxP ships prebuilt inside the NVIDIA HPC Benchmarks Apptainer image.
Launching it multi-node layers additional blockers on top of Section 1.

## 2.1 Blockers/errors and their fixes

### Blocker A — host `mpirun` drives a container MPI app: `MPI_Init` hangs

The obvious first attempt reuses the general pattern from Section 1, with each
rank running the app inside `apptainer exec`:

```bash
mpirun ... apptainer exec --nv "$SIF" /workspace/hpl-mxp.sh ...
```

Single-node works (all shared-memory). Multi-node ranks **spawn** onto the right
nodes, but the run then **hangs in `MPI_Init`** — `Time Use` freezes, no HPL
output, no error.

**Root cause.** A *host* `mpirun` (host HPC-X 2.25.1 OpenMPI 4.1.9a1) was driving
a *container* MPI application (the container's own HPC-X OpenMPI 4.1.9a1 at
`/opt/hpcx`). Same version number, **different build**. The container ranks'
ORTE/PMIx runtime therefore could not complete the cross-node handshake with the
host `mpirun`, so `MPI_Init` blocked forever. A minimal 2-node `MPI_Allreduce`
built with the container `mpicc` hung identically inside `MPI_Init`.

This is **not** an InfiniBand problem (IB was visible and active inside the
container on compute nodes) and **not** an env-pollution problem (`ldd` confirmed
the app links its own `libmpi.so.40` via RPATH). It is a launcher/MPI-build
mismatch.

**Fix — "Approach 1": consistent container MPI end-to-end.** Run the
**container's own `mpirun`** and launch the remote `orted` **inside the container**
via a `pbsdsh` bridge, so `mpirun` + `orted` + app all use the same container MPI
build. The bridge is `rsh_pbsdsh_container.sh`, and it required three concrete
fixes (Blockers B–D below). Verified with a 4-rank / 2-node `MPI_Allreduce`
(`sum=6 expect=6`).

### Blocker B — `pbsdsh` unavailable inside the container

The bridge runs `pbsdsh` *inside* the container. By default the container cannot
see the PBS binaries or the job's spool directory.

**Fix.** Bind them in:

```bash
-B /opt/pbs:/opt/pbs \
-B /var/spool/pbs:/var/spool/pbs
```

### Blocker C — quoting of the reconstructed `orted` command

The reconstructed `orted` command Open MPI hands to the bridge contains double
quotes and parentheses, e.g. `-mca ess "env"` and
`-mca orte_node_regex "hpc-gaas-g[2:8-9]@0(2)"`. Wrapping it in double quotes
breaks those tokens.

**Fix.** Pass the reconstructed command **single-quoted** through the two shell
layers (`pbsdsh` → `apptainer exec` → `bash -c`). The command itself contains no
single quotes, so a raw single-quote wrap preserves the embedded double quotes
and parentheses intact.

### Blocker D — `orted --daemonize` → `Bus error` after SIF unmount

`orted --daemonize` forks/backgrounds itself. The ephemeral `apptainer exec`
returns, the SIF's `squashfuse` mount is torn down (timeout), and the
now-backgrounded `orted` dereferences a stale mount → `Bus error`.

**Fix.** Strip `--daemonize`. `pbsdsh -o` already detaches, so daemonization is
unnecessary; keeping `orted` in the foreground keeps the container mounted for
its lifetime.

`multi-node-test/rsh_pbsdsh_container.sh` (the Approach-1 bridge, with B/C/D):

```bash
#!/bin/bash
# plm_rsh_agent for the CONTAINER's own mpirun: launches the remote orted INSIDE
# the container so the MPI stack is consistent end-to-end.
set -u
HOST="$1"; shift
[ -r "${PBS_NODEFILE:-}" ] || { echo "PBS_NODEFILE unreadable" >&2; exit 1; }

idx=$(awk -v h="$HOST" '
  { gsub(/\r$/,""); sub(/^[ \t]+/,""); sub(/[ \t]+$/,""); if ($0=="") next }
  { if ($0==h && !done) { print n; done=1; exit } }
  { if (!($0 in seen)) { seen[$0]=1; n++ } }
' "$PBS_NODEFILE")
[ -z "$idx" ] && { echo "host $HOST not in PBS_NODEFILE" >&2; exit 1; }

cmd=""
for a in "$@"; do
  [ "$a" = "--daemonize" ] && continue   # Blocker D: stay in foreground
  cmd="${cmd} ${a}"
done

SIF="/home/pham0094/hpl_hpcg_hplmxp_container/hpc-benchmarks_26.02.sif"
APPT="/usr/local/apptainer/1.4.1/bin/apptainer"
PRE="export PATH=/usr/local/apptainer/1.4.1/bin:/usr/local/squashfuse/0.5.2/bin:/usr/local/gocryptfs/2.5.0/bin:\$PATH; export LD_LIBRARY_PATH=/usr/local/squashfuse/0.5.2/lib:\$LD_LIBRARY_PATH;"

# Blocker B: bind pbs + spool. Blocker C: single-quote the orted command.
exec /opt/pbs/bin/pbsdsh -n "$idx" -o -- sh -c \
  "${PRE} ${APPT} exec --nv ${SIF} bash -c '${cmd}'"
```

### Blocker E — `libnvidia-ml.so.1` missing on remote ranks (NVML load failure)

After Approach 1, MPI spawn and `orted` launch both worked (the bridge emitted its
expected `cmd=[...]` line), but the app immediately failed on the remote ranks:

```
/workspace/hpl-mxp-linux-x86_64/xhpl_mxp: error while loading shared libraries: libnvidia-ml.so.1: cannot open shared object file: No such file or directory
```

followed by `mpirun` aborting with the first failing process being a **remote**
rank (`Process name: [[…],3]`, vpid 3 on the second node).

**Root cause.** `xhpl_mxp` has a direct `DT_NEEDED` on `libnvidia-ml.so.1`. That
library is driver-provided; it is **not** shipped in the SIF and **not** in
`/usr/local/cuda/lib64`. Apptainer's `--nv` flag mounts it correctly at
`/.singularity.d/libs/libnvidia-ml.so.1` (and points the *local* rank's
`LD_LIBRARY_PATH` at `/.singularity.d/libs`). But the remote `orted`'s
reconstructed `LD_LIBRARY_PATH` dropped that path, so remote ranks could not
resolve the library even though it was physically mounted.

Diagnostic artifact (`probe_nvml.pbs`, printing `LD_LIBRARY_PATH` per rank):

```
# local rank, host mpirun container (works):
LD_LIBRARY_PATH=...:/usr/local/nvidia/lib:/usr/local/nvidia/lib64:/.singularity.d/libs
# remote rank, container orted (broken):
LD_LIBRARY_PATH=/usr/local/cuda/compat/lib.real:/usr/local/mpi/lib:/usr/local/mpi/lib:
```

In both cases the file itself is present:

```
find / -name 'libnvidia-ml.so.1'   # -> /.singularity.d/libs/libnvidia-ml.so.1
```

so the problem is purely that the path is absent from the remote `LD_LIBRARY_PATH`.

**Fix.** Propagate the full `--nv` library path to every rank by exporting the
environment through `mpirun`:

```bash
-x PATH -x LD_LIBRARY_PATH
```

After this, all ranks resolve the library:

```
libnvidia-ml.so.1 => /.singularity.d/libs/libnvidia-ml.so.1
```

> **Note.** A bare `ldd xhpl_mxp` also reports `libiomp5.so => not found`. This is
> a red herring: the real run's `hpl-mxp.sh` sources `hpc-benchmarks-gpu-env.sh`,
> which adds the bundled Intel OpenMP (`lib/omp`) to `LD_LIBRARY_PATH`.

## 2.2 Working launch excerpt (HPL-MxP)

This is the validated, end-to-end working form (container `mpirun` +
`rsh_pbsdsh_container.sh` + the `-x` environment fix). It is parametrized over
`N` nodes × `G` GPUs/node; `run_hplmxp_multinode_baseline.pbs` is this exact
recipe.

```bash
#!/bin/bash
#PBS -N HPL_MXP_MULTINODE
#PBS -q gpu_as
#PBS -P hpc_admin
#PBS -l place=scatter               # distinct physical nodes (Blocker 5)
#PBS -l walltime=00:30:00

set -euo pipefail
cd "$PBS_O_WORKDIR"

GPUS=2                            # GPUs (and ranks) per node
module purge
module load apptainer/1.4.1 nvhpc/26.3 squashfuse/0.5.2 gocryptfs/2.5.0
chmod +x "$PWD/rsh_pbsdsh_container.sh"

SIF="/home/pham0094/hpl_hpcg_hplmxp_container/hpc-benchmarks_26.02.sif"
NNODES=$(sort -u "$PBS_NODEFILE" | wc -l)
NPROCS=$((NNODES * GPUS))

# Process grid nprow x npcol = NPROCS, npcol >= nprow (square-ish).
NPCOL=$(awk -v r="$NPROCS" 'BEGIN {
  n=int(sqrt(r)); if (n*n<r) n++;
  for (c=n; c<=r; c++) if (r%c==0) { print c; exit }
}')
NPROW=$((NPROCS / NPCOL))

# De-duplicated hostfile with explicit per-node slot count (Blocker 8).
awk -v g="$GPUS" '{ sub(/\r$/,""); if (!seen[$0]++) print $0 " slots=" g }' \
  "$PBS_NODEFILE" > "$PWD/hostfile"

# GPU affinity: node-local rank 0..G-1 -> local GPU 0..G-1.
GPU_AFFINITY=$(seq -s: 0 $((GPUS - 1)))

# Approach 1: container's own mpirun + container orted bridge (Blockers A-D),
# with -x to propagate the --nv library path to remote ranks (Blocker E).
apptainer exec --nv \
  -B /opt/pbs:/opt/pbs \
  -B /var/spool/pbs:/var/spool/pbs \
  -B "$PWD":"$PWD" \
  "$SIF" \
  /usr/local/mpi/bin/mpirun -np "$NPROCS" \
    --hostfile "$PWD/hostfile" \
    --mca plm_rsh_agent "$PWD/rsh_pbsdsh_container.sh" \
    --mca plm_rsh_no_tree_spawn 1 \
    --mca plm_rsh_num_concurrent 1 \
    --mca routed direct \
    -x PATH -x LD_LIBRARY_PATH \
    --bind-to none \
    /workspace/hpl-mxp.sh \
      --gpu-affinity "$GPU_AFFINITY" \
      --nprow "$NPROW" \
      --npcol "$NPCOL" \
      --nporder row \
      --n 120000 \
      --nb 1024 \
      --skip-tests 1 \
      --monitor-gpu 1 \
      --monitor-gpu-interval 10 \
      --monitor-gpu-pcie-width-warning 16 \
      --monitor-gpu-pcie-gen-warning 5
```

### Per-rank GPU affinity

GPU mapping is driven by the **node-local** rank, not the global rank. `hpl-mxp.sh`
reads `OMPI_COMM_WORLD_LOCAL_RANK` and maps it into `CUDA_VISIBLE_DEVICES` via the
`--gpu-affinity` list. For `2 × 4` (8 ranks):

```
rank 0..3 -> node0, local rank 0..3
rank 4..7 -> node1, local rank 0..3
```

`nvidia-smi -L` inside the container enumerates each node's GPUs as local indices
`0..G-1`, so `--gpu-affinity 0:1:2:3` maps each local rank to the correct local
GPU on every node.

## 2.3 Scaling results (proof of a successful multi-node launch)

Submitted sequentially (one config at a time). Fixed benchmark parameters across
all configs: `N = 120000`, `NB = 1024`, `--nporder row`, `--skip-tests 1`,
sloppy-type FP16. Each run reported a finite normalized residual and `PASSED`
the HPL-MxP verification.

| layout (nodes×GPUs) | ranks | nprow×npcol | normalized residual | GFLOPS | per-GPU |
|---|---|---|---|---|---|
| 2×1 | 2 | 1×2 | 8.57e-04 | 9.34e+04 | 4.67e+04 |
| 2×2 | 4 | 2×2 | 7.94e-04 | 3.01e+05 | 7.52e+04 |
| 2×4 | 8 | 2×4 | 6.76e-04 | 2.07e+05 | 2.59e+04 |
| 2×8 | 16 | 4×4 | 5.59e-05 | 2.03e+05 | 1.27e+04 |
| 3×1 | 3 | 1×3 | 7.59e-04 | 8.21e+04 | 2.74e+04 |
| 3×2 | 6 | 2×3 | 6.79e-04 | 1.15e+05 | 1.92e+04 |
| 3×4 | 12 | 3×4 | 5.79e-04 | 1.41e+05 | 1.17e+04 |
| 3×8 | 24 | 4×6 | 3.70e-05 | 2.27e+05 | 9.45e+03 |

Representative verification line (2×2):

```
||Ax-b||_oo / (EPS * (||A||_oo * ||x||_oo + ||b||_oo) * N) = 7.940890E-04 ...... PASSED
N = 120000, NB = 1024, NPROW = 2, NPCOL = 2, SLOPPY-TYPE = FP16
       GFLOPS = 3.0804e+05, per GPU = 77010.59  ------ The HPL-MxP performance to report
```

Outputs are preserved per attempt under `multi-node-test/outputs/`
(`hplmxp_mn_<layout>_a2.{o,e}`, attempt tag `a2` = the Approach-1 + NVML-fix
sweep).

> The `GFLOPS` excerpt above is from the standalone `2×2` validation run (job
> `55802.gaas`); the same config in the sweep table reports `3.01e+05` GFLOPS
> because of normal run-to-run variance (different node placement) on the shared
> cluster. All runs are PASSED; the performance numbers are not the focus of this
> setup log.

---

## Appendix — key files

| file | role |
|---|---|
| `rsh_pbsdsh.sh` | general `pbsdsh` bridge (host `mpirun` / native apps) |
| `rsh_pbsdsh_container.sh` | Approach-1 bridge (container `mpirun` + container `orted`) |
| `run_hplmxp_multinode_baseline.pbs` | validated HPL-MxP multi-node baseline |
| `run_hplmxp_baseline_sweep_seq.sh` | sequential sweep driver (attempt-tagged outputs) |
| `probe_nvml.pbs` | NVML library-availability diagnostic (per-rank `LD_LIBRARY_PATH`) |