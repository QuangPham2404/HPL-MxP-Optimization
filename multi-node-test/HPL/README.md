# HPL (HPL-NVIDIA)

Standard FP64 Linpack benchmark from the NVIDIA HPC Benchmarks container
(`/workspace/hpl.sh` → `xhpl`). Reads its input from an `HPL.dat` file; one GPU
per MPI process.

## Launch script

`run_hpl_baseline.pbs` — Approach-1 multi-node launch (container `mpirun` +
`rsh_pbsdsh_container.sh` bridge, `-x PATH -x LD_LIBRARY_PATH`). It generates an
`HPL.dat` with a generic problem (`N=200704`, `NB=1024`) and a square-ish process
grid `P x Q = ranks`.

## Baselines

| config | select | ranks | grid (P×Q) |
|---|---|---|---|
| 1x4 | `select=1:ngpus=4` | 4 | 2×2 |
| 2x4 | `select=2:ngpus=4` | 8 | 2×4 |
| 3x4 | `select=3:ngpus=4` | 12 | 3×4 |

Submit one at a time from this directory (see `../GAAS_MULTINODE_SETUP.md` for
the sequential-submission rule):

```bash
qsub -v LABEL=1x4 -l select=1:ngpus=4 run_hpl_baseline.pbs
qsub -v LABEL=2x4 -l select=2:ngpus=4 run_hpl_baseline.pbs
qsub -v LABEL=3x4 -l select=3:ngpus=4 run_hpl_baseline.pbs
```

Outputs land in `outputs/`. A successful run reports a finite normalized
residual and a `PASSED` verification line in `outputs/<job>.o`.