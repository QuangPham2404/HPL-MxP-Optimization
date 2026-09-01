# multi-node-test

Directory for validating and documenting the GAAS multi-node launch path, first
for general multi-node MPI jobs and then for the containerized HPL-MxP benchmark.

The full technical write-up lives in `GAAS_MULTINODE_SETUP.md`; this README only
summarizes the directory and the debugging milestones.

## Directory summary

| file | role |
|---|---|
| `GAAS_MULTINODE_SETUP.md` | **the** detailed setup/debug write-up (general + HPL-MxP) |
| `MANUAL_INSPECTION_ERROR.md` | error-log for the multi-node `MPI_Init` hang (resolved) |
| `rsh_pbsdsh.sh` | general `pbsdsh` bridge (host `mpirun` / native apps) |
| `rsh_pbsdsh_container.sh` | Approach-1 bridge (container `mpirun` + container `orted`) |
| `run_hplmxp_multinode_baseline.pbs` | validated HPL-MxP multi-node baseline (parametrized N×G) |
| `run_hplmxp_baseline_sweep_seq.sh` | sequential 8-config sweep driver (attempt-tagged) |
| `probe_*.pbs` | diagnostic probes (`mpi`, `envfix`, `approach1_mpi`, `approach1_recon`, `nvml`, `scaling`, `launch`) |
| `run_scaling_sweep*.sh`, `probe_scaling.pbs` | spawn-only scaling validation |
| `outputs/` | per-attempt PBS `.o`/`.e` evidence (results) |

## Milestones

### 1. General multi-node launch

- **Distinct nodes** — `place=scatter` required (`select=N:ngpus=G` alone can
  pack chunks onto one node).
- **No TM / rsh / ssh transport** — Open MPI here has no `tm` PLM/RAS component;
  `pbs_tmrsh` and `rsh` are absent and inter-node SSH is signal-killed. `pbsdsh`
  is the only working cross-node spawn path.
- **`rsh_pbsdsh.sh` bridge** — maps hostname → vnode index → `pbsdsh -n -o`,
  used as `plm_rsh_agent`.
- **Rank mapping** — de-duplicated hostfile with explicit `slots=G`; do not set
  `mpiprocs`; submit jobs sequentially.
- **Spawn sweep passes** — 2/3-node × 1/2/4-GPU layouts all launch correctly.

### 2. HPL-MxP multi-node launch

- **`MPI_Init` hang (root cause)** — host `mpirun` drove a container MPI app:
  same OpenMPI version, different build → ORTE/PMIx handshake never completed.
- **Approach 1** — run the container's own `mpirun` with a bridge that launches
  the remote `orted` inside the container (bind `/opt/pbs` + `/var/spool/pbs`,
  single-quote the `orted` line, strip `--daemonize`).
- **Cross-node MPI verified** — 4-rank / 2-node `MPI_Allreduce` PASSES.
- **NVML load fix** — `xhpl_mxp` needs `libnvidia-ml.so.1`; remote `orted` dropped
  the `--nv` `/.singularity.d/libs` path → added `-x PATH -x LD_LIBRARY_PATH`.
- **Full baseline succeeds** — 2×2 validated, then all 8 configs (2×1 … 3×8)
  report finite residuals and PASSED verification.