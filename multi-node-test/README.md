# Multi-node Test

Validating and documenting the GAAS multi-node HPL-MxP launch path.

## Status: validated

The cross-node launch mechanism is **working** and has been verified with a
full scaling sweep (2/3 nodes × 1/2/4 GPUs). See
[`GAAS_MULTINODE_SETUP.md`](GAAS_MULTINODE_SETUP.md) for the explanation of
what breaks on GAAS, the fixes, and a walkthrough example.

## What works

| item | result |
|---|---|
| Distinct-node placement | `place=scatter` is required |
| Cross-node transport | `pbsdsh` via the `rsh_pbsdsh.sh` bridge (SSH/rsh/`pbs_tmrsh` all unavailable) |
| Launch model | host `mpirun` → `apptainer exec --nv` per rank |
| Env to remote ranks | `-x PATH -x LD_LIBRARY_PATH` (for squashfuse/gocryptfs SIF mount) |
| Rank mapping | de-duplicated hostfile with explicit `slots=G` |

## Scaling sweep results (all passed)

Submitted sequentially (see `run_scaling_sweep_seq.sh`). Each node gets exactly
`G` ranks with local ranks 0..G-1.

| config | ranks | verified |
|---|---|---|
| 2 × 1 GPU | 2 | ✅ |
| 2 × 2 GPUs | 4 | ✅ |
| 2 × 4 GPUs | 8 | ✅ |
| 3 × 1 GPU | 3 | ✅ |
| 3 × 2 GPUs | 6 | ✅ |
| 3 × 4 GPUs | 12 | ✅ |

## Key files

- `rsh_pbsdsh.sh` — the `plm_rsh_agent` bridge (hostname → vnode → `pbsdsh -n`).
- `probe_scaling.pbs` — parametrized launch-validation probe (any N×G).
- `run_scaling_sweep.sh` — submits the 6-config sweep concurrently.
- `run_scaling_sweep_seq.sh` — submits sequentially (reliable; use this one).

## Milestones

1. **v1** — `select=2:ngpus=4` packed both chunks onto one 8-GPU node
   (`place=scatter` missing). Fixed by adding `place=scatter`.
2. **v2** — discovered the transport gap: no `tm` PLM, no `rsh`, no
   `pbs_tmrsh`, and inter-node SSH is blocked. `pbsdsh` is the only working
   cross-node transport.
3. **v3/v4** — built `rsh_pbsdsh.sh`; host `mpirun` + `apptainer exec` model
   works end-to-end (per-rank GPU visibility verified).
4. **v5/scale** — fixed remote SIF mount (`-x PATH -x LD_LIBRARY_PATH`), and
   rank mapping (de-dup hostfile with `slots=G`, `no_tree_spawn` +
   `routed direct`). Full 6-config sweep passes when submitted sequentially.

## Known caveats

- Do **not** set `mpiprocs` in `select` (it breaks `pbsdsh -n` vnode indexing).
- Submitting many multi-node jobs at once can race
  ("No nodes available" / "all nodes ... filled"); submit sequentially.
- Harmless `WARNING: group: unknown groupid 1304617061` from Apptainer
  (unmapped GID in the container).