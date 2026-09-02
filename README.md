# SVRaaS

SVRaaS is the deployment and service layer for the Sentiment–Volatility Ratio modeling project. It turns the existing AR, ARIMA, MLP, and LSTM research models into a rolling artifact-generation and serving system designed to support a public dashboard.

The original model repositories remain the reproducible research baseline. This repository contains the deployment-oriented model runner, refresh logic, shared artifact storage, internal API service, and Docker Swarm configuration used to operate the models as a service.

## Project Goal

The goal is to support a rolling monthly SVR dashboard by separating model computation, artifact storage, and result serving from public presentation.

The current implementation:

- monitors FRED for newly available monthly model data
- runs the AR, ARIMA, MLP, and LSTM workflows sequentially
- exports dashboard-ready JSON artifacts
- stores completed artifacts on shared NFS-backed storage
- serves completed four-model result sets through an internal read-only API

The resulting JSON artifacts are intended to be consumed by the website-serving infrastructure without exposing model execution or shared artifact storage directly.

## Architecture Status

### Implemented

SVRaaS currently consists of three Docker Swarm service layers:

```text
Persistent model runner
        ↓
Shared NFS artifact storage
        ↓
Internal Plumber2 API
```

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

#### Internal API service

SVRaaS includes a read-only Plumber2 API deployed as a Docker Swarm service.

The API runs independently of the model runner, mounts the shared artifact store read-only, and assembles coherent four-model result sets from completed artifacts.

The deployed API uses three replicas and remains stateless so multiple API tasks can serve the same completed artifact set.

The API currently exposes:

```text
GET /health
GET /v1/results/latest
```

The API does not fetch FRED data, execute models, decide when models should refresh, or modify artifacts.

### Next

The next major integration step is connecting the website-serving infrastructure to the internal API so the SVR dashboard can consume completed JSON results.

The specific website-to-API integration mechanism has not yet been implemented.

### Future

Possible future work includes:

- integration with the `aurora-solaria` dashboard frontend
- a unified SVRaaS Swarm stack
- additional deployment and reproducibility improvements
- additional operational tooling and validation

A separately public API or cache layer is not part of the current SVRaaS architecture. If public API access becomes useful later, it can be designed as a separate concern.

## Current Status

The storage, persistent model-runner, and internal API container implementations are complete and merged into `main`.

The storage and runner architecture has been validated through a clean cold-start workflow in which:

- storage was deployed with an empty artifact cache
- the persistent runner detected that no completed model suite existed
- AR, ARIMA, MLP, and LSTM executed automatically
- four fresh JSON artifacts were written to shared storage
- the runner returned to its normal monitoring loop
- subsequent checks detected that the artifacts were current and did not launch another model run

The internal Plumber2 API is also containerized and deployed through Docker Swarm against the shared artifact store using read-only NFS access.

The remaining system-level work is integrating the internal API with the website presentation layer.

## Design Notes

Detailed architecture and implementation documentation is maintained under:

```text
docs/
```

The documentation covers model execution, refresh behavior, shared artifact storage, Docker Swarm deployment, API responsibilities, and the boundary between SVRaaS and future website integration.

## Related Research Repositories

The existing model repositories remain the research baseline for this project:

- `SVR-AR`
- `SVR-ARIMA`
- `SVR-MLP`
- `SVR-LSTM`

SVRaaS adapts and orchestrates those model workflows for a rolling deployment-oriented system.
