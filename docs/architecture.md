# SVRaaS Architecture

## Purpose

SVRaaS is the deployment and service layer for the Sentiment–Volatility Ratio modeling project.

Its purpose is to turn the AR, ARIMA, MLP, and LSTM research workflows into a rolling model-generation and serving system that can update as new monthly data becomes available and provide completed results to downstream consumers.

The architecture separates:

- model execution and refresh monitoring
- shared artifact storage
- internal read-only API serving
- website presentation

The website must never execute model code directly.

Model computation happens independently, completed results are written as JSON artifacts, and the internal API reads and serves coherent completed model results.

---

## Current Architecture

SVRaaS currently consists of three Docker Swarm service layers:

```text
                 FRED
                   ↓
        persistent model runner
             Swarm service
             replicas: 1
                   ↓
        AR → ARIMA → MLP → LSTM
                   ↓
            JSON artifacts
                   ↓
       NFS-Ganesha artifact store
             Swarm service
             replicas: 1
                   ↓
            read-only NFS
                   ↓
         Plumber2 internal API
             Swarm service
             replicas: 3
                   ↓
       future website integration
```

The three implemented service responsibilities are intentionally distinct:

```text
runner
  computes and writes model results

storage
  provides shared artifact storage

API
  reads, validates, and serves completed results
```

The website integration boundary has not yet been implemented.

The current API is an internal service. Its container listens on port `8000`, but the current API Swarm stack does not publish that port externally.

---

## Core Design Principles

### 1. Keep model execution separate from API serving

The model runner owns:

- checking whether newer source data is available
- deciding whether a model refresh is needed
- executing the model suite
- writing completed JSON artifacts

The internal API owns:

- reading completed artifacts
- validating artifact contents
- assembling a coherent four-model result set
- returning JSON
- reporting whether artifact storage is available

The API must not:

- fetch FRED data
- execute models
- decide whether source data is newer
- orchestrate model execution
- modify model artifacts

This separation allows the modeling implementation and serving implementation to evolve independently as long as the artifact contract remains compatible.

---

### 2. Keep the model runner single-replica

The model runner is deployed as a persistent Docker Swarm service with:

```text
replicas: 1
permanent node-placement constraint: none
```

The runner is intentionally single-replica because the model suite performs an ordered write workflow against shared artifact storage.

Running multiple runner replicas could allow concurrent suites to execute and write model artifacts at the same time.

The runner therefore relies on Swarm for placement and restart behavior while preserving one active model workflow at a time.

---

### 3. Keep each model in a separate R process

The four model workflows are packaged in one runner image, but they do not execute inside one shared R session.

`run_all.sh` executes the models sequentially as separate `Rscript` processes:

```text
run_all.sh
    ↓
AR
    ↓
ARIMA
    ↓
MLP
    ↓
LSTM
```

This preserves process isolation between model families and reduces the risk of:

- stale R objects
- package state leaking between models
- memory contamination
- TensorFlow/Keras state carrying between neural-network models
- model-to-model side effects

If any model exits unsuccessfully, `run_all.sh` stops immediately and later models are not started.

Because LSTM runs last, the presence of a successfully completed LSTM artifact is used as the completion marker for the model suite.

---

### 4. Treat the API as a read-only consumer

The API mounts the same shared artifact store used by the runner, but its mount is read-only.

The API is designed only as a read-only consumer and has no model-publication or refresh responsibilities.

This keeps the direction of data flow simple:

```text
runner
  ↓ writes
artifact storage
  ↓ reads
API
```

---

## Persistent Refresh Monitoring

Refresh behavior is implemented inside the persistent model runner rather than in a separate orchestrator service.

`run_forever.sh` owns the monitoring and refresh decision.

The current decision flow is:

```text
persistent runner starts
        ↓
query FRED UMCSENT metadata
        ↓
determine newest available model month
        ↓
inspect latest completed LSTM artifact
        ↓
read metadata.latest_model_month
        ↓
compare artifact month with FRED month
```

The result of that comparison determines what happens next:

```text
artifact month is current
        ↓
do not run models
        ↓
sleep and check again

newer FRED month exists
        ↓
run complete model suite

no completed LSTM artifact exists
        ↓
run complete model suite

artifact storage cannot be read reliably
        ↓
do not run models
        ↓
return to normal polling
```

Normal availability polling is controlled by:

```text
SVRAAS_CHECK_INTERVAL=60
```

The current Swarm deployment therefore checks once every 60 seconds when no model suite is running.

If the model suite itself fails, the runner uses:

```text
SVRAAS_RETRY_INTERVAL=3600
```

before attempting the model workflow again.

Model execution is synchronous.

While `run_all.sh` is running, the persistent runner is blocked waiting for it to finish.

A single runner instance therefore does not continue polling or launch another model suite while the current suite is executing.

---

## Model Data Window

The deployed model workflows are no longer limited to the original fixed capstone end date.

The runners retrieve and prepare the historical data required for the current available model month rather than stopping at the original research-period boundary.

The original model repositories remain the reproducible research baseline, while the SVRaaS copies adapt those workflows for rolling execution.

Refresh monitoring and model data preparation remain separate concerns:

- `run_forever.sh` determines whether the suite needs to run
- the individual R workflows retrieve and prepare the data required for model execution

---

## Artifact Contract

Model artifact output is controlled through:

```text
SVRAAS_ARTIFACT_ROOT
```

The deployed runner sets:

```text
SVRAAS_ARTIFACT_ROOT=/artifacts
```

The API also uses:

```text
SVRAAS_ARTIFACT_ROOT=/artifacts
```

The model and API code treat that location as an ordinary filesystem path.

They do not contain NFS-specific logic and do not need to know that `/artifacts` is backed by shared network storage.

For native or local model execution, the model scripts retain a local `artifacts` fallback when `SVRAAS_ARTIFACT_ROOT` is not supplied.

The model suite writes individual timestamped JSON artifacts such as:

```text
ar_<timestamp>.json
arima_<timestamp>.json
mlp_<timestamp>.json
lstm_<timestamp>.json
```

Each completed artifact includes model metadata used by downstream logic.

In particular, the persistent runner reads:

```text
metadata.latest_model_month
```

from the newest completed LSTM artifact when determining whether the model suite is current.

The API uses the model month to identify a coherent completed AR, ARIMA, MLP, and LSTM cohort.

The current architecture does not use a published manifest, hash-addressed bundle, `current/` directory, or `latest.json` publication layer.

A different cohort-discovery mechanism could be introduced later if it provides a clear operational benefit, but it is not required by the current architecture.

---

## Shared NFS Artifact Storage

SVRaaS uses a dedicated NFS-Ganesha storage service deployed through Docker Swarm.

The current storage service is:

- single-replica
- NFSv4.1
- TCP
- published on port `2049`
- exposed through the Docker Swarm ingress routing mesh
- backed by a Docker local volume
- deployed from an immutable GHCR image digest

The NFS export is:

```text
/artifacts
```

Inside the storage container, the backing Docker volume is mounted at:

```text
/export/artifacts
```

The Ganesha/VFS container runs with the container accommodation required by the current implementation:

```text
CAP_DAC_READ_SEARCH
```

---

## Artifact Storage Is an Ephemeral Cache

The shared artifact store is intentionally treated as a rebuildable cache rather than durable authoritative storage.

Whenever the storage container starts, its startup logic clears:

```text
/export/artifacts
```

before the NFS service begins serving the export.

This means that storage recreation or relocation intentionally produces an empty artifact store.

The expected recovery path is:

```text
storage starts
        ↓
artifact cache is empty
        ↓
persistent runner checks storage
        ↓
no completed LSTM artifact exists
        ↓
runner executes full model suite
        ↓
fresh artifacts repopulate NFS
```

This behavior is intentional.

The model runners retrieve the historical data necessary to rebuild their current artifacts, so preserving stale model artifacts across storage recreation is not currently required.

---

## Storage Backing Volume vs. NFS Client Volumes

The storage service, runner service, and API service use different Docker volume concepts.

They should not be treated as the same volume.

### Storage backing volume

The storage stack defines a Docker local volume that provides filesystem storage inside the NFS-Ganesha container:

```text
Docker local volume
        ↓
/export/artifacts
        ↓
NFS-Ganesha
        ↓
NFS export /artifacts
```

This volume contains the actual server-side artifact files.

### Runner NFS client volume

The runner stack separately defines an NFS client mount using Docker's local volume driver.

Conceptually:

```yaml
volumes:
  artifacts:
    driver: local
    driver_opts:
      type: nfs
      o: addr=127.0.0.1,nfsvers=4.1,rw
      device: :/artifacts
```

The runner therefore receives read/write access to `/artifacts`.

### API NFS client volume

The API stack independently defines its own NFS client mount:

```yaml
volumes:
  artifacts:
    driver: local
    driver_opts:
      type: nfs
      o: addr=127.0.0.1,nfsvers=4.1,ro
      device: :/artifacts
```

The API therefore receives read-only access to the same NFS export.

These stack-scoped volumes are NFS client configurations, not the NFS server's backing volume.

Docker creates the client volumes from the stack definitions when services are scheduled onto Swarm nodes that do not already have those stack-scoped volumes.

Manual creation of the NFS client volume on every Swarm node is therefore not required.

This behavior was explicitly validated during the runner deployment on previously unprepared Swarm nodes.

---

## NFS Read Safety

During Swarm validation, one node reproduced a first-access NFS behavior where an artifact-directory access could fail with:

```text
OSError: [Errno 121] Remote I/O error: '/artifacts'
```

An immediate second access succeeded.

Testing showed that the behavior was attempt-specific rather than delay-specific, and it was reproduced through more than one client access method.

The underlying cause has not been established.

The runner therefore protects the complete artifact-read operation with up to three immediate attempts.

Conceptually:

```text
attempt complete artifact read
        ↓
success
        → continue normally

failure
        ↓
retry immediately
        ↓
up to 3 total attempts
```

If all three attempts fail:

- artifact storage is considered unavailable
- the condition is not interpreted as an empty artifact store
- the model suite does not start
- the runner returns to its normal polling interval

This distinction is important because an unreadable artifact store must not accidentally be interpreted as "no artifacts exist."

Without that protection, a transient NFS failure could incorrectly trigger an expensive four-model regeneration.

The observed first-access behavior remains an operational investigation item.

No specific Docker Engine, kernel, operating system, or NFS-client version has been established as the cause.

---

## FRED Credentials

The FRED API key is not baked into the runner image.

Production Docker Swarm deployment uses the external secret:

```text
fred_key
```

The runner entrypoint resolves the credential in this order:

```text
1. /run/secrets/fred_key
2. FRED_KEY environment variable for local development
3. fail startup if neither exists
```

If `/run/secrets/fred_key` exists but is empty or unreadable, startup fails.

The runner does not silently fall back to the environment variable when a Docker secret file exists but is invalid.

The Swarm-secret path has been validated on nodes without the local development `.env` file.

---

## TensorFlow Runtime on Non-AVX Hardware

Some target SVRaaS Swarm hardware does not support AVX CPU instructions.

Official TensorFlow wheels produced `SIGILL` when executed on that hardware.

The SVRaaS runner therefore consumes the separately published custom TensorFlow build from:

```text
https://github.com/leg3/tensorflow-nonavx
```

The runner image pins the custom wheel by release URL and SHA256 and verifies the checksum during image construction.

The resulting TensorFlow runtime has been validated on the target non-AVX Xeon hardware.

Both the MLP and LSTM workflows successfully execute with this runtime.

This is a current deployment requirement for the supported non-AVX hardware, not a hypothetical compatibility concern.

The runner Dockerfile remains the source of truth for the exact TensorFlow wheel release and checksum.

---

## Docker Swarm Deployment

SVRaaS currently deploys storage, runner, and API as separate Swarm stacks.

This keeps the three service responsibilities independently deployable while the architecture is still evolving.

### Storage service

The current storage deployment uses:

```text
replicas: 1
protocol: NFSv4.1 over TCP
published port: 2049
publish mode: Swarm ingress
artifact export: /artifacts
backing path: /export/artifacts
restart condition: on-failure
update order: stop-first
image reference: immutable GHCR digest
```

The storage service is intentionally single-replica.

### Model runner service

The current runner deployment uses:

```text
replicas: 1
placement constraint: none
restart condition: any
restart delay: 5 seconds
update order: stop-first
artifact mount: shared NFS read/write
artifact root: /artifacts
FRED credential: external fred_key secret
normal check interval: 60 seconds
model failure retry: 3600 seconds
image reference: immutable GHCR digest
```

`stop-first` update behavior prevents the old and replacement runner tasks from overlapping during a service update.

The lack of a permanent placement constraint allows Swarm to schedule the runner onto an available node while the single-replica design prevents concurrent model-write workflows.

### Internal API service

The current API deployment uses:

```text
replicas: 3
max replicas per node: 1
restart condition: any
restart delay: 5 seconds
update parallelism: 1
update order: stop-first
update failure action: rollback
rollback parallelism: 1
rollback order: stop-first
artifact mount: shared NFS read-only
artifact root: /artifacts
NFS version: 4.1
container port: 8000
published Swarm port: none
image reference: immutable GHCR digest
```

The API is stateless and read-only, allowing multiple replicas to serve the same completed artifact set.

Limiting the service to one replica per node distributes the API tasks across available Swarm nodes.

The API container includes its own health check against:

```text
GET /health
```

The health check runs against the local container listener on port `8000`.

---

## Internal Plumber2 API

The repository contains a containerized read-only Plumber2 API.

The current application exposes:

```text
GET /health
GET /v1/results/latest
```

The API reads completed model artifacts and identifies a coherent four-model result set.

Its responsibility boundary is intentionally narrow.

The API may:

- inspect artifact storage
- read completed artifacts
- validate artifact contents
- assemble a coherent AR/ARIMA/MLP/LSTM result set
- return JSON
- report whether artifact storage is available

The API must not:

- fetch FRED data
- execute models
- determine whether source data is newer
- trigger model execution
- modify model artifacts

The API requires an absolute artifact-root path when configured through:

```text
SVRAAS_ARTIFACT_ROOT
```

The deployed service uses:

```text
SVRAAS_ARTIFACT_ROOT=/artifacts
```

The API container is based on:

```text
rocker/r-ver:4.6.1
```

Its runtime R dependencies include:

```text
plumber2
jsonlite
```

The service binds Plumber2 to:

```text
0.0.0.0:8000
```

Port `8000` is exposed by the container image but is not currently published by the API Swarm stack.

This preserves the API as an internal service until the website integration boundary is deliberately implemented.

---

## Validated Cold-Start Behavior

The storage and persistent-runner architecture has passed a clean cold-start validation.

The validation removed:

- the runner stack
- the storage stack
- existing SVRaaS runner/client volumes from Swarm nodes
- old storage backing volumes from Swarm nodes

Storage was then redeployed from a clean state.

The resulting workflow was:

```text
new storage service starts
        ↓
/export/artifacts is empty
        ↓
runner is deployed without a placement constraint
        ↓
runner finds no completed LSTM artifact
        ↓
AR runs
        ↓
ARIMA runs
        ↓
MLP runs
        ↓
LSTM runs
        ↓
four fresh JSON artifacts exist in NFS
        ↓
runner returns to 60-second monitoring
        ↓
next FRED/artifact comparison matches
        ↓
no unnecessary second model suite is launched
```

The validated cold-start suite produced one fresh artifact for each model family.

This confirms the intended recovery property of the architecture: an empty artifact cache is sufficient to cause the persistent runner to regenerate the current model result set automatically.

---

## Website Integration

The next system-level boundary is integration between the internal SVRaaS API and the website presentation layer.

The `aurora-solaria` website remains the intended consumer of completed SVR results.

Its eventual SVR responsibilities may include:

- hosting the public dashboard and research page
- rendering charts and tables
- consuming completed model results
- presenting model and methodology information
- avoiding direct model execution

The specific network and application boundary between `aurora-solaria` and the internal API has not yet been implemented.

That integration should preserve the existing architecture rule:

```text
website
  does not execute models
  does not write artifacts
  does not require direct access to artifact storage
```

The website should obtain completed results through the serving boundary rather than reaching directly into model execution or NFS storage.

---

## Future Operational Work

The following remain possible future improvements:

- a unified SVRaaS Swarm stack containing storage, runner, and API
- a cold-reset wrapper for repeatable removal of SVRaaS stacks and node-local volumes
- clearer naming between storage backing volumes and NFS client volumes
- explicit `SIGTERM` and `SIGINT` handling in `run_forever.sh`
- stronger dependency and image-version pinning where useful
- semantic runner and API image releases
- further investigation of the first-access NFS behavior
- an explicit cohort manifest or other publication mechanism if operationally useful
- integration with the `aurora-solaria` dashboard frontend

Future components should not be described as current behavior until they have been implemented and validated.

---

## Main Design Principle

The architecture remains intentionally layered:

```text
Persistent runner computes model results.
        ↓
Shared artifact storage holds completed results.
        ↓
Internal API reads and serves completed results.
        ↓
Website presentation consumes those results.
```

The website must never cause model computation directly.
