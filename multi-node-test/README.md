# Multi-node Test

## Purpose

Validate the GAAS multi-node HPL-MxP launch path: 2 compute nodes, 4 GPUs
each, 8 MPI ranks total (4 per node). This directory holds the cross-node
launcher probe before any real HPL-MxP multi-node baseline is run.

## Desired resource mapping

- PBS allocation: `select=2:ngpus=4` (2 chunks x 4 GPUs = 2 distinct nodes).
- Launcher: Open MPI `-np 8 --map-by ppr:4:node` via the container.
- Cross-node spawn agent: PBS Pro `pbs_remsh` (`/opt/pbs/bin/pbs_remsh`),
  since the GAAS Open MPI (host and container) is built without the `tm`
  component (only `rsh`/`slurm`/`isolated`) and there is no `pbs_tmrsh`.
- Explicit `--hostfile "$PBS_NODEFILE"` required because there is no
  `ras: tm` auto-detection.
- Per-node GPU affinity: `--gpu-affinity 0:1:2:3` (local indices).

## Attempts and results

| Attempt | PBS job | Outcome |
|---|---|---|
| `probe_multinode_launch_v1` | `55456.gaas` | FAILED — both chunks landed on the same node |
| `probe_multinode_launch_v2` | not submitted | pending |

## Error record — attempt v1

`select=2:ngpus=4` did **not** produce two distinct nodes. The job's
`PBS_NODEFILE` contained the same host twice:

```text
=== PBS_NODEFILE ===
hpc-gaas-g16
hpc-gaas-g16
```

Both 4-GPU chunks were packed onto a single 8-GPU node (`hpc-gaas-g16`).
Stage 0 (host `mpirun -np 8 --map-by ppr:4:node`) then failed because Open MPI
deduplicated the hostfile to one node and reported:

```text
There are not enough slots available in the system to satisfy the 4
slots that were requested by the application:
  hostname
```

### Suspected cause

GAAS nodes expose 8 GPUs each. `select=2:ngpus=4` alone lets the scheduler
satisfy both 4-GPU chunks on one 8-GPU node, so no distinct-node separation
is enforced.

### Planned fix

Add a scatter placement directive to force chunks onto separate physical
nodes:

```text
#PBS -l select=2:ngpus=4
#PBS -l place=scatter
```

This is staged in `probe_multinode_launch_v1.pbs` as attempt `_v2` (new
`-o`/`-e` names), committed but **not yet submitted**.

## Next action (next session)

1. Submit `probe_multinode_launch_v1.pbs` (attempt `_v2`) and verify
   `PBS_NODEFILE` now lists two distinct nodes.
2. Confirm stage 0/1 cross-node spawn and stage 2 per-rank GPU visibility.
3. If `place=scatter` is insufficient or unsupported, investigate explicit
   node chunking (e.g. `select=1:ngpus=4+1:ngpus=4` or hostname-specific
   constraints) as the follow-up.