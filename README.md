# SVRaaS

SVRaaS is the planned service layer for the Sentiment–Volatility Ratio modeling project. It is intended to turn the existing AR, ARIMA, MLP, and LSTM research models into a rolling artifact-generation system that can support a public dashboard.

The original model repositories remain the reproducible research baseline. This repository will house the deployment-oriented compute, orchestration, artifact, and service architecture.

## Project Goal

The goal is to support a rolling monthly SVR dashboard by separating model computation from public presentation.

SVRaaS will eventually:

- fetch and validate the latest monthly SVR input data
- run the AR, ARIMA, MLP, and LSTM model workflows
- export dashboard-ready JSON artifacts
- expose internal status and artifact endpoints
- support a public API/cache layer consumed by the `aurora-solaria` website

## Planned Components

```text
R/model compute layer
  Runs the model workflows and generates JSON artifacts.

Refresh orchestrator
  Determines when new data is ready and coordinates model execution.

Internal Plumber service
  Provides internal health, status, manifest, artifact, and refresh endpoints.

Public API/cache bridge
  Serves cached JSON artifacts to the public website without exposing model execution.

aurora-solaria dashboard frontend
  Fetches the public API data and renders the SVR dashboard.
```

## Current Status

This repository is in the planning and scaffold phase.

No production compute service, public API, or dashboard integration has been implemented yet. The initial focus is documenting the architecture and preparing the repository structure for incremental development.

## Design Notes

The current system design is documented in:

```text
docs/architecture.md
```

That document captures the major design decisions around model isolation, orchestration, artifact generation, Plumber, public API caching, and website integration.

## Related Research Repositories

The existing model repositories remain the research baseline for this project:

- `SVR-AR`
- `SVR-ARIMA`
- `SVR-MLP`
- `SVR-LSTM`

SVRaaS will adapt and orchestrate that modeling work for a rolling deployment-oriented system.
