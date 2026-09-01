# Multi-node Test

Validating and documenting the GAAS multi-node HPL-MxP launch path.

---

## ⚠️ SESSION HAND-OFF (2026-09-01) — read this first

The previous state claimed cross-node launch was "validated", but that validation
only proved **rank spawn** (echo/nvidia-smi), *not* MPI communication. The actual
HPL-MxP run hung in `MPI_Init` across nodes. This session diagnosed it and
**solved cross-node MPI communication** via a new launch model (Approach 1).
Cross-node `MPI_Init` + `MPI_Allreduce` now complete successfully (verified with
a 4-rank / 2-node test).

### Root cause of the hang

Host `mpirun` (host HPC-X 2.25.1 OpenMPI 4.1.9a1) drives a **container** MPI app
(container's own HPC-X OpenMPI 4.1.9a1 at `/opt/hpcx`). Same version, different
build → the container ranks' ORTE/PMIx runtime could not complete the cross-node
session with the host `mpirun`, so `MPI_Init` blocked. (Single-node worked because
it is all shared-memory, no cross-node handshake.) InfiniBand was fine and fully
visible inside the container — transport was never the problem.

### The fix (Approach 1) — consistent container MPI end-to-end

Run the **container's own `mpirun`** and launch the remote `orted` **inside the
container** via a pbsdsh bridge. Everything (mpirun + orted + app) uses the same
container MPI, so the ORTE/PMIx handshake works.

Three concrete fixes were required (all in `rsh_pbsdsh_container.sh`):

1. **`pbsdsh` from inside the container** — bind `/opt/pbs` and
   `/var/spool/pbs` into the container.
2. **Quoting** — the reconstructed `orted` command contains double quotes and
   parentheses (`-mca ess "env"`, `-mca orte_node_regex "...@0(2)"`); it must be
   passed to the container shell **single-quoted**, not double-quoted.
3. **Strip `--daemonize`** — `orted --daemonize` forks/backgrounds, so the
   ephemeral `apptainer exec` returns and unmounts the SIF (squashfuse timeout),
   then the backgrounded orted hits `Bus error`. `pbsdsh -o` already detaches, so
   daemonization is unnecessary; keeping orted in the foreground keeps the
   container mounted.

### Working launch recipe (the pattern to reuse)

```bash
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
    "$PWD/my_mpi_app"
```

Where `hostfile` is the de-duplicated node list with `slots=G`, and the bridge
`rsh_pbsdsh_container.sh` maps hostname → vnode index, strips `--daemonize`, and
wraps `orted` in `apptainer exec` (with squashfuse/gocryptfs absolute paths).

### NEXT STEPS (do these in order)

1. **Update `run_hplmxp_multinode_baseline.pbs`** to use the Approach-1 launch
   (container `mpirun` + `rsh_pbsdsh_container.sh`) instead of the current host
   `mpirun` form. Replace the HPL app with `apptainer exec ... mpirun ...
   /workspace/hpl-mxp.sh --gpu-affinity ... --nprow ... --npcol ... --n 120000
   --nb 1024 --skip-tests 1 --monitor-gpu ...`. Same bind mounts as above.
2. **Validate 2×2 HPL baseline** (single job) — confirm the run reports a finite
   residual + GFLOPS (not just MPI init).
3. **Run the full sweep** (`run_hplmxp_baseline_sweep_seq.sh`, or update it to the
   Approach-1 form) for 2×1 … 3×8, submitted sequentially.
4. Update `GAAS_MULTINODE_SETUP.md` to mark the host-`mpirun` model as superseded.

---

## Status: cross-node MPI working (Approach 1); HPL sweep not yet re-run

Cross-node rank **spawn** was validated earlier (full 2/3-node × 1/2/4-GPU sweep),
and this session validated cross-node **MPI communication** (4-rank allreduce).
The full HPL-MxP sweep still needs to be re-run under Approach 1.

## What works

| item | result |
|---|---|
| Distinct-node placement | `place=scatter` is required |
| Cross-node spawn transport | `pbsdsh` (SSH/rsh/`pbs_tmrsh` all unavailable) |
| Cross-node MPI data plane | container `mpirun` + container `orted` (Approach 1) |
| Launch model | container `mpirun` → `apptainer exec --nv` per rank |
| Remote SIF mount | squashfuse/gocryptfs absolute paths (see bridge) |
| Rank mapping | de-duplicated hostfile with explicit `slots=G` |

## Key files

- `rsh_pbsdsh.sh` — host-`mpirun` bridge (hostname → vnode → `pbsdsh -n`). **Only
  validates spawn; superseded for real MPI runs.**
- `rsh_pbsdsh_container.sh` — **Approach-1 bridge**: hostname → vnode →
  `pbsdsh -n ... apptainer exec ... orted` (strips `--daemonize`, single-quotes).
- `probe_approach1_mpi.pbs` — end-to-end cross-node `MPI_Allreduce` test (PASSED).
- `probe_approach1_recon.pbs` — confirms `pbsdsh` + remote SIF mount inside container.
- `probe_multinode_mpi.pbs` / `probe_multinode_envfix.pbs` — diagnosis of the hang.
- `run_hplmxp_multinode_baseline.pbs` — HPL baseline (still host-`mpirun`; **needs
  updating to Approach 1**).
- `run_hplmxp_baseline_sweep_seq.sh` — sequential 8-config baseline driver.
- `probe_scaling.pbs` / `run_scaling_sweep_seq.sh` — spawn-only scaling validation.

## Milestones

1. **v1** — `place=scatter` forces separate nodes.
2. **v2** — no `tm`/`rsh`/`pbs_tmrsh`, inter-node SSH blocked → `pbsdsh` only path.
3. **v3/v4** — `rsh_pbsdsh.sh`; host `mpirun` + `apptainer exec` spawns ranks.
4. **v5/scale** — remote SIF mount + rank mapping; 6-config spawn sweep passes.
5. **2026-09-01 (Approach 1)** — diagnosed a real `MPI_Init` cross-node hang;
   fixed by running the container's own `mpirun` with a bridge that launches the
   container `orted` (single-quote + strip `--daemonize`). 4-rank allreduce PASSES.

## Known caveats

- Do **not** set `mpiprocs` in `select` (breaks `pbsdsh -n` vnode indexing).
- Submit multi-node jobs **sequentially** (concurrent submission races).
- Harmless `WARNING: group: unknown groupid 1304617061` from Apptainer.
- Approach 1 requires the file mode of `rsh_pbsdsh*.sh` to stay `0755` in git
  (a local `chmod +x` on GAAS otherwise shows up as an uncommitted change and
  blocks `git pull --ff-only`).
- `-x PATH -x LD_LIBRARY_PATH` is **required** so the container's `--nv`
  `/.singularity.d/libs` (and thus `libnvidia-ml.so.1`, needed by `xhpl_mxp`,
  and `libcuda.so.1`) propagate to remote ranks. Without it, remote ranks fail
  to load the NVML library even though the SIF is mounted.