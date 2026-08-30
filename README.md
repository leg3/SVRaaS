# SVRaaS

SVRaaS is the deployment and service layer for the Sentiment–Volatility Ratio modeling project. It turns the existing AR, ARIMA, MLP, and LSTM research models into a rolling artifact-generation system designed to support a public dashboard.

The original model repositories remain the reproducible research baseline. This repository contains the deployment-oriented model runner, refresh logic, shared artifact storage, internal API implementation, and Docker Swarm configuration used to operate the models as a service.

## Project Goal

The goal is to support a rolling monthly SVR dashboard by separating model computation from public presentation.

The current implementation:

- monitors FRED for newly available monthly model data
- runs the AR, ARIMA, MLP, and LSTM workflows sequentially
- exports dashboard-ready JSON artifacts
- stores completed artifacts on shared NFS-backed storage
- provides internal API application logic for reading and validating completed model results

Future service layers will expose those completed results to the public dashboard without exposing model execution or internal artifact storage directly.

## Architecture Status

### Implemented

#### Persistent model runner

A single-replica Docker Swarm runner packages all four model workflows:

```text
AR
→ ARIMA
→ MLP
→ LSTM
```

The runner remains active after startup and monitors FRED metadata to determine when a new model month is available.

When regeneration is required, it executes the complete model suite sequentially. If one model fails, later models are not started.

The completed LSTM artifact acts as the suite-completion marker because LSTM runs last.

#### Shared artifact storage

SVRaaS includes a single-replica NFS-Ganesha storage service deployed through Docker Swarm.

The model runner mounts the shared artifact store as a normal filesystem path and writes completed JSON artifacts there. The R model code does not need to know that the backing storage is NFS.

Artifact storage is intentionally treated as a rebuildable cache. Recreating or relocating the storage service starts with an empty artifact store, and the persistent runner regenerates the model artifacts when no completed model suite is present.

#### Internal API application

The repository contains the read-only Plumber2 API application used to inspect completed model artifacts and assemble coherent four-model result sets.

The API is intentionally separated from model execution. It may read and validate completed artifacts, but it does not fetch FRED data, execute models, decide when models should refresh, or modify artifacts.

### In Progress / Next

The next major deployment step is containerizing the Plumber2 API and connecting it to the shared artifact store through a read-only NFS mount.

The deployed API is expected to remain stateless so that multiple replicas can serve the same completed artifact set.

### Future

Planned future work includes:

- a public API/cache bridge
- integration with the `aurora-solaria` dashboard frontend
- a unified SVRaaS Swarm stack
- deployment and reproducibility polish
- additional operational tooling and validation

These components are not part of the current implemented architecture.

## Current Status

The storage and persistent model-runner implementations are complete and merged into `main`.

The current system has been validated through a clean cold-start workflow in which:

- storage was deployed with an empty artifact cache
- the persistent runner detected that no completed model suite existed
- AR, ARIMA, MLP, and LSTM executed automatically
- four fresh JSON artifacts were written to shared storage
- the runner returned to its normal monitoring loop
- subsequent checks detected that the artifacts were current and did not launch another model run

The internal Plumber2 API application and tests are also present in the repository. Containerizing that API and attaching it read-only to the shared artifact storage is the next major implementation step.

The public API/cache layer and dashboard integration remain future work.

## Design Notes

Detailed architecture and implementation documentation is maintained under:

```text
docs/
```

The documentation covers the separation between model execution and serving, artifact generation, shared storage, refresh behavior, API responsibilities, and planned public-facing integration.

## Related Research Repositories

The existing model repositories remain the research baseline for this project:

- `SVR-AR`
- `SVR-ARIMA`
- `SVR-MLP`
- `SVR-LSTM`

SVRaaS adapts and orchestrates those model workflows for a rolling deployment-oriented system.
