# Manual Inspection Error Log

## Case `mn-2026-09-01-mpi-init-hang`

- **Status:** OPEN (USER_ACTION_REQUIRED)
- **Affected workflow:** HPL-MxP multi-node baseline (`multi-node-test/`).
- **Date / job IDs:** 2026-09-01. Jobs `55767.gaas` (HPL 2x2), `55768.gaas`
  (mpi probe), `55770.gaas` (env-fix probe).

### Observed error

Multi-node HPL-MxP hangs with `Time Use` frozen (~10s) and no HPL output.
A minimal 2-node `MPI_Allreduce` test (built with the container's `mpicc`)
hangs inside `MPI_Init` — no rank prints "after MPI_Init" before walltime.

### Confirmed facts

- Rank *spawn* across distinct nodes works (pbsdsh bridge + host `mpirun`).
- InfiniBand is visible and ACTIVE inside the container on compute nodes
  (UCX `rc_mlx5`/`ud_mlx5`/`dc_mlx5`, `mlx5_bond_0`, PORT_ACTIVE).
- The container app correctly resolves its own `libmpi.so.40`
  (`/opt/hpcx/ompi/lib`) via RPATH; `-x LD_LIBRARY_PATH` does not pollute it.
- Host and container both report Open MPI 4.1.9a1, but are separate HPC-X builds
  (host `/usr/local/nvhpc/.../hpcx-2.25.1`, container `/opt/hpcx`).
- Single-node HPL (container `mpirun`, all shared-memory) works fine.

### Suspected cause

Launch model mismatch: host `mpirun` (host HPC-X) launches a container MPI
application (container HPC-X). The container ranks' ORTE/PMIx runtime cannot
complete the cross-node session handshake with the host `mpirun`, so `MPI_Init`
blocks. The existing bridge was only ever validated for rank *spawn*, not MPI
*communication*.

### Suggested fixes (for user review — not applied)

1. **Consistent container MPI (preferred):** run the container's own `mpirun`
   (inside the container) and change the `plm_rsh_agent` bridge to launch the
   remote `orted` *inside* the container (`apptainer exec SIF orted …`), binding
   `$PBS_NODEFILE`/pbsdsh into the container.
2. **Consistent host MPI:** bind-mount the host HPC-X MPI into the container and
   make `xhpl_mxp` resolve the host's `libmpi` (consistent with host `mpirun`).
3. Site-supported PMIx/launcher integration if available on GAAS.

### Resolution

Pending.