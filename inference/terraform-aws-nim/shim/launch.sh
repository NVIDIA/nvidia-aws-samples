#!/bin/sh
# SageMaker shim entrypoint — runs inside the shim container on every SageMaker endpoint.
#
# Startup sequence:
#   1. Sync NGC model profile cache from S3 (if MODEL_PROFILE_CACHE is set) — reduces cold start times
#   2. Sync open weight model files from S3 (if OPEN_WEIGHTS_S3_URI is set, open-weight path only)
#   3. Load vLLM recipe env vars from S3 (if RECIPE_ENV_S3_URI is set, open-weight + enable_vllm_recipe)
#   4. Start Caddy on :8080 — rewrites /invocations -> framework infer path, /ping -> health path
#   5. Start NIM or vLLM, then monitor: if the inference process exits, kill Caddy and exit the
#      container so SageMaker marks the endpoint Failed immediately instead of waiting out the timeout
#
# Framework path/health mapping is in caddy-config.json (controlled by NIM_HEALTH_PATH env var).
# Adding support for a new framework (e.g. Triton) means adding its paths to caddy-config.json
# and passing the correct NIM_HEALTH_PATH from the SageMaker model environment variables.
#
# See DEVELOPER_REFERENCE.md for architecture details and known issues.

usage() {
  echo "Usage: $0 [-p PORT] [-b BACKEND_PORT] [-c CONFIG_URL] [-e ORIGINAL_ENTRYPOINT] [-a ORIGINAL_CMD]"
  echo "  -p PORT                Port to listen on (default: 8080)"
  echo "  -b BACKEND_PORT        Backend port (default: 80)"
  echo "  -c CONFIG_URL          URL or path of the configuration file (default: /opt/caddy-config.json)"
  echo "  -e ORIGINAL_ENTRYPOINT Path to the original entrypoint script (default: /usr/bin/serve)"
  echo "  -a ORIGINAL_CMD        Original command arguments (default: empty)"
  exit 1
}

PORT=8080
BACKEND_PORT=
CONFIG_URL="/opt/caddy-config.json"
ORIGINAL_ENTRYPOINT="/usr/bin/serve"
ORIGINAL_CMD=""

while getopts "p:b:c:e:a:" opt; do
  case ${opt} in
    p ) PORT=${OPTARG} ;;
    b ) BACKEND_PORT=${OPTARG} ;;
    c ) CONFIG_URL=${OPTARG} ;;
    e ) ORIGINAL_ENTRYPOINT=${OPTARG} ;;
    a ) ORIGINAL_CMD=${OPTARG} ;;
    * ) usage ;;
  esac
done

# Auto-detect Caddy backend port when not explicitly set via -b.
# Standard NIM images bake NIM_HTTP_API_PORT=8000 (the NIM's nginx frontend port).
# Custom NIMs without NIM_HTTP_API_PORT fall back to NIM_SERVER_PORT, then 8000.
if [ -z "$BACKEND_PORT" ]; then
  BACKEND_PORT=${NIM_HTTP_API_PORT:-${NIM_SERVER_PORT:-8000}}
  echo "Caddy backend port auto-detected: ${BACKEND_PORT} (from NIM_HTTP_API_PORT/NIM_SERVER_PORT)"
else
  echo "Caddy backend port explicitly set: ${BACKEND_PORT}"
fi

download_file() {
  url=$1
  output=$2
  curl -L -o "$output" "$url"
  if [ $? -ne 0 ]; then
    echo "Failed to download $url"
    exit 1
  fi
}

# ── Model profile cache sync ───────────────────────────────────────────────────
# If MODEL_PROFILE_CACHE is set, sync the pre-cached NGC model profile from S3
# into CACHE_PATH before NIM starts. ~2-5 min vs ~5-10 min from NGC.
# The model-profile-cache CodeBuild project populates this S3 prefix on every apply.
if [ -n "${MODEL_PROFILE_CACHE:-}" ]; then
    echo "Syncing model profile cache from ${MODEL_PROFILE_CACHE} into ${CACHE_PATH:-/opt/nim/.cache}..."
    mkdir -p "${CACHE_PATH:-/opt/nim/.cache}"
    aws s3 sync "${MODEL_PROFILE_CACHE}/" "${CACHE_PATH:-/opt/nim/.cache}/" --no-progress
    echo "Cache sync complete."
fi

# Open weight sync — downloads model weights from S3 into /opt/ml/model before the framework starts.
# Populated by the weight-fetch CodeBuild project during terraform apply.
if [ -n "${OPEN_WEIGHTS_S3_URI:-}" ]; then
    echo "Syncing model weights from ${OPEN_WEIGHTS_S3_URI} into /opt/ml/model..."
    mkdir -p /opt/ml/model
    aws s3 sync "${OPEN_WEIGHTS_S3_URI}/" /opt/ml/model/ --no-progress
    echo "Weight sync complete."
fi

# vLLM Recipe env — source optimized flags written by weight-fetch CodeBuild.
# Sets RECIPE_BASE_ARGS, RECIPE_EXTRA_ARGS, and any model-specific env vars.
# RECIPE_ENV_S3_URI is empty for NIM endpoints and when enable_vllm_recipe = false.
if [ -n "${RECIPE_ENV_S3_URI:-}" ]; then
    if aws s3 cp "${RECIPE_ENV_S3_URI}" /tmp/recipe.env 2>/dev/null; then
        . /tmp/recipe.env
        echo "vLLM recipe env loaded from ${RECIPE_ENV_S3_URI}"
    else
        echo "No recipe env at ${RECIPE_ENV_S3_URI} — using vLLM defaults"
    fi
fi

# Assemble final vLLM command for open weight endpoints.
# Order: base command + recipe base args + recipe variant args + user args.
# User args (VLLM_USER_ARGS) come last so they override any recipe defaults.
if [ -n "${VLLM_USER_ARGS:-}${RECIPE_BASE_ARGS:-}${RECIPE_EXTRA_ARGS:-}" ]; then
    ORIGINAL_CMD="${ORIGINAL_CMD} ${RECIPE_BASE_ARGS:-} ${RECIPE_EXTRA_ARGS:-} ${VLLM_USER_ARGS:-}"
    echo "Final vLLM command: ${ORIGINAL_CMD}"
fi

# Additional scripts — run in the order defined in additional_scripts[].
# ADDITIONAL_SCRIPTS is a newline-separated list of S3 URIs (set by Terraform from
# additional_scripts[*].source; local files are uploaded to S3 automatically).
# All scripts complete before Caddy and NIM start. A non-zero exit aborts startup.
if [ -n "${ADDITIONAL_SCRIPTS:-}" ]; then
    i=0
    echo "$ADDITIONAL_SCRIPTS" | while IFS= read -r uri; do
        [ -z "$uri" ] && continue
        echo "=== [$(date -u '+%H:%M:%S')] Running additional script [$i]: $uri ==="
        aws s3 cp "$uri" /tmp/additional_script_${i}.sh
        chmod +x /tmp/additional_script_${i}.sh
        /tmp/additional_script_${i}.sh
        i=$((i + 1))
    done
fi

# Check if Caddy is already present
if [ ! -f "/usr/local/bin/caddy" ]; then
  echo "Caddy not found, downloading..."
  download_file "https://caddyserver.com/api/download?os=linux&arch=amd64" "/tmp/caddy"
  mv /tmp/caddy /usr/local/bin/caddy
  chmod +x /usr/local/bin/caddy
else
  echo "Caddy already present."
fi

# Check if CONFIG_URL is a URL or a local file path
if echo "$CONFIG_URL" | grep -qE '^https?://'; then
  echo "Downloading configuration file from URL..."
  download_file "$CONFIG_URL" "/usr/local/bin/caddy-config.json"
  CONFIG_FILE_PATH="/usr/local/bin/caddy-config.json"
else
  echo "Using local configuration file..."
  CONFIG_FILE_PATH="$CONFIG_URL"
fi

HEALTH_PATH="${NIM_HEALTH_PATH:-/v1/health/ready}"

CONFIG_FILE=$(mktemp)
cat "$CONFIG_FILE_PATH" | sed "s/\${PORT}/$PORT/g; s/\${BACKEND_PORT}/$BACKEND_PORT/g; s|\${HEALTH_PATH}|$HEALTH_PATH|g" > $CONFIG_FILE

if [ ! -s "$CONFIG_FILE" ]; then
  echo "Configuration file is empty or not created properly"
  exit 1
fi

cat $CONFIG_FILE

echo "Running Caddy..."
/usr/local/bin/caddy run --config $CONFIG_FILE &
CADDY_PID=$!

sleep 5

env

# Execute the original container entrypoint script and command.
# Newer NIM versions (e.g. nemotron-3-nano 2.0.2+) do not ship nvidia_entrypoint.sh —
# they set up the NVIDIA environment in the image and run the NIM command directly.
if [ -f "$ORIGINAL_ENTRYPOINT" ]; then
    echo "Running $ORIGINAL_ENTRYPOINT $ORIGINAL_CMD ..."
    $ORIGINAL_ENTRYPOINT $ORIGINAL_CMD &
    NIM_PID=$!
else
    echo "Entrypoint $ORIGINAL_ENTRYPOINT not found — running $ORIGINAL_CMD directly."
    $ORIGINAL_CMD &
    NIM_PID=$!
fi

# Monitor the NIM process. If it exits for any reason, kill Caddy and exit the
# container immediately. Without this, Caddy keeps running and returning 502s,
# which SageMaker interprets as "still starting" — causing it to wait the full
# startup timeout before marking the endpoint as Failed.
echo "Monitoring NIM process (PID $NIM_PID)..."
while kill -0 $NIM_PID 2>/dev/null; do
    sleep 5
done

echo "NIM process (PID $NIM_PID) exited — shutting down container"
kill $CADDY_PID 2>/dev/null
exit 1
