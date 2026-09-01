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

## Multi-node blocker — `nvidia_peermem` kernel module (GPUDirect RDMA)

HPL-NVIDIA uses **NVSHMEM** for cross-node communication, which requires
**GPUDirect RDMA** over InfiniBand via the `nvidia_peermem` kernel module.

- **1x4 (single node) works** — all GPUs are local (NVLink), no RDMA needed.
- **2x4 / 3x4 fail** with NVSHMEM aborting at init:

```
ibrc.cpp:1854: neither nv_peer_mem, or nvidia_peermem detected. Skipping transport.
topo.cpp:489:   [GPU 1] Peer GPU 4 is not accessible, exiting ...
                 building transport map failed / nvshmem common init failed
```

The launch setup is **not** at fault — the Approach-1 MPI launch (container
`mpirun` + `rsh_pbsdsh_container.sh` bridge) works and ranks/`MPI_Init` succeed.
Only the NVSHMEM data-plane transport fails.

The module exists on GAAS (`/lib/modules/.../nvidia-peermem.ko`, v580.65.06) but
is **not loaded**. It must be loaded **on every GPU compute node** (and ideally
configured to load at boot):

```bash
# root on each GPU compute node (or site modprobe/modules-load.d config)
modprobe nvidia_peermem
```

Until the admin loads it, only the 1x4 (single-node) HPL baseline can run.