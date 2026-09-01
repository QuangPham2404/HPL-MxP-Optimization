# HPL-MxP

Mixed-precision (Tensor Core) HPL from the NVIDIA HPC Benchmarks container
(`/workspace/hpl-mxp.sh` → `xhpl_mxp`). One GPU per MPI process.

## Launch script

`run_hplmxp_baseline.pbs` — Approach-1 multi-node launch (container `mpirun` +
`rsh_pbsdsh_container.sh` bridge, `-x PATH -x LD_LIBRARY_PATH`). Generic
baseline `N=120000`, `NB=1024`, row major, square-ish grid `nprow x npcol =
ranks`, `--skip-tests 1`.

## Baselines

| config | select | ranks | grid (nprow×npcol) |
|---|---|---|---|
| 1x4 | `select=1:ngpus=4` | 4 | 2×2 |
| 2x4 | `select=2:ngpus=4` | 8 | 2×4 |
| 3x4 | `select=3:ngpus=4` | 12 | 3×4 |

Submit one at a time from this directory:

```bash
qsub -v LABEL=1x4 -l select=1:ngpus=4 run_hplmxp_baseline.pbs
qsub -v LABEL=2x4 -l select=2:ngpus=4 run_hplmxp_baseline.pbs
qsub -v LABEL=3x4 -l select=3:ngpus=4 run_hplmxp_baseline.pbs
```

Outputs land in `outputs/`. A successful run reports a finite residual and
`PASSED` verification plus a `GFLOPS` line in `outputs/<job>.o`.