# SageMaker shim image — Caddy reverse proxy + launch script layered on top of an inference base.
#
# SageMaker hardcodes two paths on every container it manages: POST /invocations (inference)
# and GET /ping (health check). No inference framework serves these natively, so this shim
# intercepts them and rewrites to the framework's actual paths before proxying.
#
# One Dockerfile, two image types depending on endpoint path:
#   NIM path:         ECR base image (copied from nvcr.io by base-sync CodeBuild)
#   Open weight path: vllm/vllm-openai:latest
#
# See DEVELOPER_REFERENCE.md for architecture details and known issues.

# ARG before FROM is required by Docker for build args used in FROM instructions.
ARG SRC_IMAGE
FROM ${SRC_IMAGE}
USER 0

ARG NIM_CMD="/opt/nim/start_server.sh"
ARG NIM_ENTRYPOINT="/opt/nvidia/nvidia_entrypoint.sh"
# Named CADDY_BACKEND_PORT not NIM_BACKEND_PORT — vLLM reads NIM_BACKEND_PORT for its
# own internal port; colliding with it causes "address already in use" at startup.
# Empty = auto-detect from NIM_HTTP_API_PORT env var at runtime (standard NIMs: 8000).
ARG CADDY_BACKEND_PORT=""
ARG CACHE_PATH="/opt/nim/.cache"
# SageMaker reads this label to auto-select an inference AMI with a matching CUDA driver.
# Empty = SageMaker picks the default. See DEVELOPER_REFERENCE.md for known AMI issues.
ARG CUDA_DRIVER_LABEL=""

ENV NIM_CMD="${NIM_CMD}"
ENV NIM_ENTRYPOINT="${NIM_ENTRYPOINT}"
ENV CADDY_BACKEND_PORT="${CADDY_BACKEND_PORT}"
ENV CACHE_PATH="${CACHE_PATH}"
ENV CADDY_CONF=/opt/caddy-config.json
# Some NIM containers include OpenMPI (Message Passing Interface — parallel computing
# communication layer used for multi-GPU/multi-node inference) and check permissions
# at startup. These vars suppress the root-user warning OpenMPI emits in containers.
ENV OMPI_ALLOW_RUN_AS_ROOT=1
ENV OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1

LABEL com.amazonaws.sagemaker.inference.cuda.verified_versions="${CUDA_DRIVER_LABEL}"

COPY launch.sh caddy-config.json /opt/

# AWS CLI baked in for S3 weight/cache syncs in launch.sh. ~100 MB against a 10-30 GB base.
# jq baked in so launch.sh can extract JSON keys from Secrets Manager payloads without
# resolving credentials at Terraform time (see the "Fetch credentials via IAM" block in launch.sh).
RUN apt-get update \
    && apt-get install -y curl unzip jq \
    && curl -fsSLo /tmp/awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws \
    && curl -Lo /tmp/caddy.tar.gz "https://github.com/caddyserver/caddy/releases/download/v2.9.1/caddy_2.9.1_linux_amd64.tar.gz" \
    && tar -xzf /tmp/caddy.tar.gz -C /usr/local/bin caddy \
    && rm /tmp/caddy.tar.gz \
    && chmod a+x /usr/local/bin/caddy /opt/launch.sh \
    && rm -rf /var/lib/apt/lists/*

# launch.sh: syncs weights/profile cache from S3, starts Caddy on :8080 (routes
# /invocations → /v1/chat/completions and /ping → health), then starts NIM/vLLM and
# monitors it — kills Caddy and exits immediately if NIM dies so SageMaker marks the
# endpoint Failed rather than waiting out the full startup timeout returning 502s.
ENTRYPOINT ["sh", "-xe", "-c", "/opt/launch.sh -c $CADDY_CONF -e $NIM_ENTRYPOINT -a \"$NIM_CMD\"${CADDY_BACKEND_PORT:+ -b $CADDY_BACKEND_PORT}"]
