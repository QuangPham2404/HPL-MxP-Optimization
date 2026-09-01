# HPCG (HPCG-NVIDIA)

High Performance Conjugate Gradient benchmark from the NVIDIA HPC Benchmarks
container (`/workspace/hpcg.sh` → `xhpcg`). One GPU per MPI process.

## Launch script

`run_hpcg_baseline.pbs` — Approach-1 multi-node launch (container `mpirun` +
`rsh_pbsdsh_container.sh` bridge, `-x PATH -x LD_LIBRARY_PATH`). Generic
baseline with a local `256 x 256 x 256` domain per rank and a `60 s` timed
portion; the 3-D process grid (`npx x npy x npz`) is auto-derived by the
benchmark from the MPI communicator.

## Baselines

| config | select | ranks |
|---|---|---|
| 1x4 | `select=1:ngpus=4` | 4 |
| 2x4 | `select=2:ngpus=4` | 8 |
| 3x4 | `select=3:ngpus=4` | 12 |

Submit one at a time from this directory:

```bash
qsub -v LABEL=1x4 -l select=1:ngpus=4 run_hpcg_baseline.pbs
qsub -v LABEL=2x4 -l select=2:ngpus=4 run_hpcg_baseline.pbs
qsub -v LABEL=3x4 -l select=3:ngpus=4 run_hpcg_baseline.pbs
```

Outputs land in `outputs/`. A successful run reports the final `GFLOP/s` (and,
unless `--b 1` is used, the validation/residual check) in `outputs/<job>.o`.