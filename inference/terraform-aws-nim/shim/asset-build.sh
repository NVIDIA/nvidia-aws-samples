# #!/bin/bash
# shellcheck shell=bash
# # FUTURE PR — Custom NIM build path (enable_asset_build).
# # Not called by any active code path. Not included in the shim Docker image.
# # Re-enable by: (1) uncommenting asset-build resources in codebuild.tf,
# #               (2) adding this file back to shim/Dockerfile COPY + chmod.
# #
# # Builds TRT engines from HuggingFace weights (HF → ONNX → TRT).
# # Default implementation: Alpamayo-1.5-10B pipeline.
# #
# # Called by the asset-build CodeBuild project (not by launch.sh).
# # launch.sh syncs the finished engines from MODEL_PROFILE_CACHE at container startup.
# #
# # To adapt this script for a different custom NIM:
# #   1. Replace Steps 1-3 below with your model's build pipeline.
# #   2. Keep the S3 fast-path check (fast path 2) and S3 upload at the bottom —
# #      they are the "build once, cache forever" pattern.
# #   3. Set enable_asset_build = true in your Terraform module call.
# #
# # Environment variables:
# #   HF_TOKEN   — HuggingFace token (REQUIRED unless S3 cache hit)
# #   PRECISION  — Engine precision: fp16 | fp8 | nvfp4  (default: fp16)
# #   ASSET_CACHE — S3 URI prefix for engine caching, e.g.
# #                 s3://my-bucket/nim-cache/g6e.12xlarge
# #                 Fast path: checks S3 first (~5 min download).
# #                 After build: uploads engines to S3 so future
# #                 cold starts skip the 45-90 min build entirely.
# #
# # Output directory: /workspace/models/models/alpamayo-1.5-10b/
# #   hf/      - HuggingFace weights (downloaded)
# #   deploy/  - separated VLM + expert checkpoints
# #   onnx/    - ONNX exports
# #   engine/  - TRT engines (what edgellm_server.py reads at runtime)
# #
# # Each step is idempotent: if the output already exists, the step is skipped.
# # First run (no cache): ~45-90 min (download + ONNX export + TRT build).
# # First run (S3 cache hit): ~5 min (S3 download only).
# # Subsequent runs with pre-built image: seconds.
# set -euo pipefail

# PRECISION="${PRECISION:-fp16}"

# BASE="/workspace/models/models/alpamayo-1.5-10b"
# HF_DIR="${BASE}/hf"
# DEPLOY="${BASE}/deploy"
# ONNX="${BASE}/onnx"
# ENGINE="${BASE}/engine"

# EXPORT_SCRIPT="/usr/local/bin/alpamayo-export.py"
# VISUAL_BUILD="/usr/local/bin/visual_build"
# LLM_BUILD="/usr/local/bin/llm_build"
# PREPROC_CFG="/usr/local/share/alpamayo/preprocessor_config.json"

# mkdir -p "${HF_DIR}" "${DEPLOY}" "${ONNX}" "${ENGINE}"

# echo "============================================"
# echo "  asset-build: download & build TRT engines"
# echo "  PRECISION   : ${PRECISION}"
# echo "  BASE        : ${BASE}"
# echo "  ASSET_CACHE : ${ASSET_CACHE:-<not set>}"
# echo "============================================"

# # ── Fast path 1: pre-built engines baked into the container image ──────────────
# if find "${ENGINE}" -type f \( -name '*.engine' -o -name '*.trt' \) 2>/dev/null | grep -q .; then
#     echo "Pre-built engines found in ${ENGINE} — skipping download and build."
#     find "${ENGINE}" -type f \( -name '*.engine' -o -name '*.trt' \) | sort
#     exit 0
# fi

# # ── Fast path 2: S3 asset cache ────────────────────────────────────────────────
# if [ -n "${ASSET_CACHE:-}" ]; then
#     echo ""
#     echo "======== Checking S3 asset cache ========"
#     if aws s3 ls "${ASSET_CACHE}/" 2>/dev/null | grep -q .; then
#         echo "Cache found — downloading engines from ${ASSET_CACHE} ..."
#         aws s3 sync "${ASSET_CACHE}/" "${ENGINE}/" --no-progress
#         echo "S3 cache download complete — skipping build."
#         find "${ENGINE}" -type f \( -name '*.engine' -o -name '*.trt' \) | sort
#         exit 0
#     else
#         echo "No cache found at ${ASSET_CACHE} — proceeding with full build."
#         echo "(Engines will be uploaded to S3 after build for future cold starts.)"
#     fi
# fi

# if [ -z "${HF_TOKEN:-}" ]; then
#     echo "ERROR: HF_TOKEN is not set. Cannot download model weights."
#     exit 1
# fi

# # ── Step 1: Download HF model ──────────────────────────────────────────────
# echo ""
# echo "======== Step 1: Download HF model ========"

# if [ ! -f "${HF_DIR}/config.json" ]; then
#     echo "Downloading nvidia/Alpamayo-1.5-10B..."
#     hf download nvidia/Alpamayo-1.5-10B --local-dir="${HF_DIR}" --token="${HF_TOKEN}"
# else
#     echo "[skip] HF model already exists"
# fi

# # Cosmos-Reason2-8B (VLM backbone referenced by config.json)
# VLM_DIR="${BASE}/Cosmos-Reason2-8B"
# if [ ! -f "${VLM_DIR}/config.json" ]; then
#     echo "Downloading nvidia/Cosmos-Reason2-8B..."
#     hf download nvidia/Cosmos-Reason2-8B --local-dir="${VLM_DIR}" --token="${HF_TOKEN}"
# else
#     echo "[skip] Cosmos-Reason2-8B already exists"
# fi

# # Patch config.json vlm_name_or_path to container-local path
# CURRENT_VLM_PATH=$(python3 -c "import json; print(json.load(open('${HF_DIR}/config.json'))['vlm_name_or_path'])" 2>/dev/null || true)
# if [ -n "${CURRENT_VLM_PATH}" ] && [ "${CURRENT_VLM_PATH}" != "${VLM_DIR}" ]; then
#     echo "Patching config.json vlm_name_or_path: ${CURRENT_VLM_PATH} -> ${VLM_DIR}"
#     python3 -c "
# import json, pathlib
# p = pathlib.Path('${HF_DIR}/config.json')
# cfg = json.loads(p.read_text())
# cfg['vlm_name_or_path'] = '${VLM_DIR}'
# p.write_text(json.dumps(cfg, indent=2))
# "
# fi

# # ── Step 1b: Separate VLM + expert ────────────────────────────────────────
# if [ ! -d "${DEPLOY}/vlm" ] || [ ! -d "${DEPLOY}/expert" ]; then
#     echo "Separating VLM + expert checkpoints..."
#     python "${EXPORT_SCRIPT}" separate \
#         --source="${HF_DIR}" \
#         --vlm_dest="${DEPLOY}/vlm" \
#         --expert_dest="${DEPLOY}/expert"
# else
#     echo "[skip] Model already separated"
# fi

# if [ ! -f "${DEPLOY}/vlm/preprocessor_config.json" ]; then
#     echo "Copying preprocessor_config.json to ${DEPLOY}/vlm/"
#     cp "${PREPROC_CFG}" "${DEPLOY}/vlm/preprocessor_config.json"
# fi

# # ── Step 2: Export to ONNX ─────────────────────────────────────────────────
# echo ""
# echo "======== Step 2: Export to ONNX (${PRECISION}) ========"

# if [ ! -f "${ONNX}/expert_fp16/expert_fp16.onnx" ]; then
#     echo "Exporting expert..."
#     python "${EXPORT_SCRIPT}" expert \
#         --source="${HF_DIR}" \
#         --dest_path="${ONNX}/expert_fp16/expert_fp16.onnx"
# else
#     echo "[skip] Expert ONNX already exists"
# fi

# case "${PRECISION}" in
#     fp16)
#         if [ ! -d "${ONNX}/language_fp16" ]; then
#             echo "Exporting LLM (fp16)..."
#             tensorrt-edgellm-export-llm \
#                 --model_dir "${DEPLOY}/vlm" \
#                 --output_dir "${ONNX}/language_fp16"
#         else
#             echo "[skip] LLM ONNX (fp16) already exists"
#         fi
#         if [ ! -d "${ONNX}/visual_fp16" ]; then
#             echo "Exporting ViT (fp16)..."
#             tensorrt-edgellm-export-visual \
#                 --model_dir "${DEPLOY}/vlm" \
#                 --output_dir "${ONNX}/visual_fp16"
#         else
#             echo "[skip] ViT ONNX (fp16) already exists"
#         fi
#         ;;
#     fp8)
#         if [ ! -d "${DEPLOY}/fp8_pths" ]; then
#             echo "Quantizing LLM to fp8..."
#             tensorrt-edgellm-quantize-llm \
#                 --model_dir "${DEPLOY}/vlm" \
#                 --output_dir "${DEPLOY}/fp8_pths" \
#                 --quantization fp8 --lm_head_quantization fp8
#         else
#             echo "[skip] fp8 quantized pths already exist"
#         fi
#         if [ ! -d "${ONNX}/language_fp8" ]; then
#             echo "Exporting LLM (fp8)..."
#             tensorrt-edgellm-export-llm \
#                 --model_dir "${DEPLOY}/fp8_pths" \
#                 --output_dir "${ONNX}/language_fp8"
#         else
#             echo "[skip] LLM ONNX (fp8) already exists"
#         fi
#         if [ ! -d "${ONNX}/visual_fp8" ]; then
#             echo "Exporting ViT (fp8)..."
#             tensorrt-edgellm-export-visual \
#                 --model_dir "${DEPLOY}/vlm" \
#                 --output_dir "${ONNX}/visual_fp8" \
#                 --quantization fp8
#         else
#             echo "[skip] ViT ONNX (fp8) already exists"
#         fi
#         ;;
#     nvfp4)
#         if [ ! -d "${DEPLOY}/nvfp4_pths" ]; then
#             echo "Quantizing LLM to nvfp4..."
#             tensorrt-edgellm-quantize-llm \
#                 --model_dir "${DEPLOY}/nvfp4_pths" \
#                 --output_dir "${DEPLOY}/nvfp4_pths" \
#                 --quantization nvfp4 --lm_head_quantization fp8
#         else
#             echo "[skip] nvfp4 quantized pths already exist"
#         fi
#         if [ ! -d "${ONNX}/language_nvfp4" ]; then
#             echo "Exporting LLM (nvfp4)..."
#             tensorrt-edgellm-export-llm \
#                 --model_dir "${DEPLOY}/nvfp4_pths" \
#                 --output_dir "${ONNX}/language_nvfp4"
#         else
#             echo "[skip] LLM ONNX (nvfp4) already exists"
#         fi
#         if [ ! -d "${ONNX}/visual_fp16" ]; then
#             echo "Exporting ViT (fp16 for nvfp4)..."
#             tensorrt-edgellm-export-visual \
#                 --model_dir "${DEPLOY}/vlm" \
#                 --output_dir "${ONNX}/visual_fp16"
#         else
#             echo "[skip] ViT ONNX (fp16) already exists"
#         fi
#         ;;
# esac

# # Patch chat template
# for lang_dir in "${ONNX}"/language_*/; do
#     template="${lang_dir}processed_chat_template.json"
#     if [ -f "${template}" ]; then
#         echo "Patching chat template: ${template}"
#         sed -i 's/"generation_prompt": "<|im_start|>assistant\\n",/"generation_prompt": "<|im_start|>assistant\\n<|cot_start|>",/g' "${template}"
#     fi
# done

# # ── Step 3: Build TRT engines ──────────────────────────────────────────────
# echo ""
# echo "======== Step 3: Build TRT engines (${PRECISION}) ========"

# VISUAL_PREC="fp16"
# [ "${PRECISION}" = "fp8" ] && VISUAL_PREC="fp8"

# VIS_ENGINE="${ENGINE}/visual_${VISUAL_PREC}"
# if [ ! -d "${VIS_ENGINE}" ] || [ -z "$(find "${VIS_ENGINE}" -name '*.engine' 2>/dev/null)" ]; then
#     echo "Building visual engine (${VISUAL_PREC})..."
#     mkdir -p "${VIS_ENGINE}"
#     cp "${PREPROC_CFG}" "${ONNX}/visual_${VISUAL_PREC}/preprocessor_config.json"
#     "${VISUAL_BUILD}" \
#         --onnxDir="${ONNX}/visual_${VISUAL_PREC}" \
#         --engineDir="${VIS_ENGINE}" \
#         --minImageTokens=180 --maxImageTokens=2880 \
#         --maxImageTokensPerImage=180 2>&1 | tee "${VIS_ENGINE}/build.log"
#     cp "${PREPROC_CFG}" "${VIS_ENGINE}/preprocessor_config.json"
# else
#     echo "[skip] Visual engine already exists"
# fi

# LANG_ENGINE="${ENGINE}/language_${PRECISION}"
# if [ ! -d "${LANG_ENGINE}" ] || [ -z "$(find "${LANG_ENGINE}" -name '*.engine' 2>/dev/null)" ]; then
#     echo "Building language engine (${PRECISION})..."
#     mkdir -p "${LANG_ENGINE}"
#     "${LLM_BUILD}" \
#         --onnxDir="${ONNX}/language_${PRECISION}" \
#         --engineDir="${LANG_ENGINE}" \
#         --vlm --minImageTokens=180 --maxImageTokens=2880 \
#         --maxInputLen=3424 --maxKVCacheCapacity=3424 \
#         2>&1 | tee "${LANG_ENGINE}/build.log"
# else
#     echo "[skip] Language engine already exists"
# fi

# EXPERT_ENGINE="${ENGINE}/expert_fp16"
# if [ ! -f "${EXPERT_ENGINE}/engine.trt" ]; then
#     echo "Building expert engine..."
#     mkdir -p "${EXPERT_ENGINE}"
#     trtexec \
#         --onnx="${ONNX}/expert_fp16/expert_fp16.onnx" \
#         --useCudaGraph --useSpinWait \
#         --profilingVerbosity=detailed --stronglyTyped --verbose \
#         --dumpProfile --maxAuxStreams=0 \
#         --dumpLayerInfo --separateProfileRun --noDataTransfers --maxTactics=2000 \
#         --saveEngine="${EXPERT_ENGINE}/engine.trt" \
#         --minShapes=seq_length:2808 --optShapes=seq_length:3072 \
#         --maxShapes=seq_length:3424 2>&1 | tee "${EXPERT_ENGINE}/build.log"
# else
#     echo "[skip] Expert engine already exists"
# fi

# # Extract action_space_cfg alongside expert engine for runtime use
# ACTION_SPACE_CFG="${EXPERT_ENGINE}/action_space_cfg.json"
# if [ ! -f "${ACTION_SPACE_CFG}" ]; then
#     echo "Extracting action_space_cfg from ${HF_DIR}/config.json..."
#     python3 -c "
# import json, pathlib
# cfg = json.loads(pathlib.Path('${HF_DIR}/config.json').read_text())
# asc = cfg.get('action_space_cfg', {})
# asc.pop('_target_', None)
# pathlib.Path('${ACTION_SPACE_CFG}').write_text(json.dumps(asc, indent=2))
# "
#     echo "Saved ${ACTION_SPACE_CFG}"
# else
#     echo "[skip] action_space_cfg.json already exists"
# fi

# echo ""
# echo "======== Build complete ========"
# find "${ENGINE}" -type f \( -name '*.engine' -o -name '*.trt' \) | sort

# # ── Upload engines to S3 asset cache ──────────────────────────────────────
# if [ -n "${ASSET_CACHE:-}" ]; then
#     echo ""
#     echo "======== Uploading engines to S3 asset cache ========"
#     echo "Destination: ${ASSET_CACHE}"
#     aws s3 sync "${ENGINE}/" "${ASSET_CACHE}/" --no-progress && \
#         echo "Upload complete. Future cold starts will download from S3 (~5 min) instead of rebuilding." || \
#         echo "WARNING: S3 upload failed — engines built successfully but not cached."
# fi

# echo ""
# echo "======== asset-build complete! ========"
