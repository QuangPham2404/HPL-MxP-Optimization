# Manual Inspection Error Log

## Case `mn-2026-09-01-mpi-init-hang`

- **Status:** RESOLVED
- **Affected workflow:** HPL-MxP multi-node baseline (`multi-node-test/`).
- **Date / job IDs:** 2026-09-01. Jobs `55767.gaas` (HPL 2x2), `55768.gaas`
  (mpi probe), `55770.gaas` (env-fix probe), `55774.gaas` (approach-1 v1),
  `55778.gaas` (approach-1 v2), `55779.gaas` (approach-1 v3, PASSED).

### Observed error

Multi-node HPL-MxP hung with `Time Use` frozen and no HPL output. A minimal
2-node `MPI_Allreduce` test (built with the container's `mpicc`) hung inside
`MPI_Init`.

### Confirmed facts

- Rank *spawn* across distinct nodes worked (pbsdsh bridge + host `mpirun`).
- InfiniBand was visible and ACTIVE inside the container on compute nodes.
- The container app correctly resolved its own `libmpi.so.40` via RPATH;
  `-x LD_LIBRARY_PATH` did not pollute it.
- Host and container were separate Open MPI 4.1.9a1 builds (host
  `/usr/local/nvhpc/.../hpcx-2.25.1`, container `/opt/hpcx`).
- Single-node HPL worked (all shared-memory).

### Suspected cause → confirmed

Launch-model mismatch: host `mpirun` drove a container MPI app; the container
ranks' ORTE/PMIx runtime could not complete the cross-node session with the host
`mpirun`.

### Resolution (Approach 1, chosen by user)

Run the container's own `mpirun` and launch the remote `orted` inside the
container via `rsh_pbsdsh_container.sh`. Three fixes were required:

1. bind `/opt/pbs` + `/var/spool/pbs` into the container.
2. single-quote the reconstructed `orted` command.
3. strip `--daemonize` (prevents the ephemeral `apptainer exec` from unmounting
   the SIF under the running orted).

Verified with job `55779.gaas`: 4 ranks passed `MPI_Init` and `MPI_Allreduce`
(`sum=6 expect=6`).

### Follow-up

Re-wire `run_hplmxp_multinode_baseline.pbs` to Approach 1, validate 2×2 HPL, then
run the full sweep. See `multi-node-test/README.md` for the hand-off.