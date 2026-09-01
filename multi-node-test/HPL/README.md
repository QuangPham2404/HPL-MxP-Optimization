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

## Non-root workaround (under investigation)

HPL-NVIDIA exposes runtime switches to bypass NVSHMEM (from the container
`TUNING` doc):

| env var | default | alternative (no GDR) |
|---|---|---|
| `HPL_USE_NVSHMEM` | `1` (NVSHMEM) | `0` → NCCL/MPI inter-GPU comm |
| `HPL_FCT_COMM_POLICY` | `0` (NVSHMEM pivoting) | `1` → Host MPI pivoting |
| `HPL_P2P_AS_BCAST` | `1` (ncclSend/Recv) | `0` ncclBcast, `2` CUDA-aware MPI, `3` MPI, `4` NVSHMEM |

`run_hpl_baseline.pbs` now defaults to `HPL_USE_NVSHMEM=0` +
`HPL_FCT_COMM_POLICY=1` (exported to ranks via `-x`), which should avoid the
`nvidia_peermem` requirement by using NCCL/MPI instead of NVSHMEM.

---

## ⚠️ SESSION HAND-OFF (read this first)

### What is complete

| benchmark | 1x4 | 2x4 | 3x4 |
|---|---|---|---|
| HPL-MxP (`../HPL-MxP/`) | ✅ PASSED | ✅ PASSED | ✅ PASSED |
| HPCG (`../HPCG/`) | ✅ VALID | ✅ VALID | ✅ VALID |
| HPL | ✅ PASSED (1.89e+05 Gflops) | ⛔ see below | not run |

HPL launch setup (Approach 1) is correct — see the `nvidia_peermem` blocker above.

### In-flight work (do NOT assume it finished)

A **non-root workaround test** for HPL 2x4 was submitted but its outcome is
**undetermined** at hand-off time:

- Job `55928.gaas` (`outputs/hpl_2x4_nosh.o/.e`), `HPL_USE_NVSHMEM=0`
  + `HPL_FCT_COMM_POLICY=1`.
- As of hand-off it had been `R` for **~8 min with NO output files created**
  (not even the `module load` line in `.e`). This is abnormal: either the
  NCCL/MPI fallback is hanging during cross-node setup, or it is merely very
  slow. **The next agent must check `qstat 55928` / `outputs/hpl_2x4_nosh.{o,e}`
  first.**

### Next steps

1. Check job `55928` and `outputs/hpl_2x4_nosh.{o,e}`:
   - If it **PASSED** → the non-root workaround works; run `3x4`
     (`qsub -v LABEL=3x4 -l select=3:ngpus=4`), then record results.
   - If it **hung/failed** → NCCL-over-IB likely also needs GPUDirect (or the
     MPI fallback is unusably slow/hanging). Investigate `HPL_P2P_AS_BCAST=2/3`
     and CUDA-aware-MPI/NCCL `NCCL_*` env vars, or fall back to requesting
     `nvidia_peermem` from the admin. **Do not delete** the `nvidia_peermem`
     note above — it is the root-cause record for the senior engineer.
2. Preserve attempt-specific `.o/.e` evidence (do not overwrite `hpl_2x4.o/.e`
   = original NVSHMEM-failure evidence; `hpl_1x4.o/.e` = PASSED).
3. `run_hpl_baseline.pbs` currently has `HPL_USE_NVSHMEM=0` as the default; if
   admin loads `nvidia_peermem`, revert default to `1` for the fast NVSHMEM path.