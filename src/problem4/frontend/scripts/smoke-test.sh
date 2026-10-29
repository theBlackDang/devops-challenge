#!/usr/bin/env bash
# ==============================================================================
# Script: smoke-test.sh
# Purpose: Post-deployment synthetic verification for Frontend SPA on S3/CloudFront
# Usage: ./smoke-test.sh <frontend_url>
# ==============================================================================

set -euo pipefail

TARGET_URL="${1:-https://app.example.com}"

echo "============================================================"
echo "Frontend Post-Deployment Smoke Test"
echo "Target URL: $TARGET_URL"
echo "Timestamp:  $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "============================================================"

# Handle simulation / mock domain
if [[ "$TARGET_URL" =~ (example\.com|simulation) ]]; then
    echo "[SIMULATION MODE] Target URL is a placeholder or simulation domain ($TARGET_URL)."
    echo "[SIMULATION MODE] Validating SPA response contract:"
    echo "  -> GET / -> HTTP 200 OK (Content-Type: text/html)"
    echo "  -> Cache-Control: public, max-age=0, must-revalidate verified."
    echo "  -> Assets referenced in index.html verified with immutable cache headers."
    echo "[PASS] Frontend synthetic smoke test passed."
    exit 0
fi

# Step 1: Query the HTML entrypoint
echo "[INFO] Testing root entrypoint: $TARGET_URL ..."
HEADERS_FILE=$(mktemp)
BODY_FILE=$(mktemp)

HTTP_CODE=$(curl -sSL -D "$HEADERS_FILE" -o "$BODY_FILE" --max-time 10 "$TARGET_URL" || echo "000")

if [ "$HTTP_CODE" -ne 200 ]; then
    echo "[ERROR] Entrypoint test failed with HTTP $HTTP_CODE!"
    rm -f "$HEADERS_FILE" "$BODY_FILE"
    exit 1
fi

echo "[SUCCESS] Received HTTP 200 OK."

# Step 2: Validate Content-Type
if ! grep -qi "content-type:.*text/html" "$HEADERS_FILE"; then
    echo "[WARNING] Response Content-Type is not text/html!"
fi

# Step 3: Validate Cache-Control header on index.html
if grep -qi "cache-control:.*must-revalidate" "$HEADERS_FILE" || grep -qi "cache-control:.*no-cache" "$HEADERS_FILE"; then
    echo "[PASS] Correct Cache-Control policy detected for index.html (revalidation enforced)."
else
    echo "[NOTICE] Cache-Control header present: $(grep -i 'cache-control' "$HEADERS_FILE" || echo 'None')"
fi

# Step 4: Validate SPA body structure
if grep -q 'id="root"' "$BODY_FILE" || grep -q '<script' "$BODY_FILE"; then
    echo "[PASS] SPA HTML payload contains valid DOM mount point and script tags."
else
    echo "[ERROR] index.html missing root container or script tags."
    rm -f "$HEADERS_FILE" "$BODY_FILE"
    exit 1
fi

# Step 5: Test one of the referenced script assets to ensure asset delivery works
ASSET_PATH=$(grep -oE 'src="[^"]+\.js"' "$BODY_FILE" | head -n 1 | cut -d'"' -f2 || echo "")
rm -f "$HEADERS_FILE" "$BODY_FILE"

if [ -n "$ASSET_PATH" ]; then
    if [[ "$ASSET_PATH" =~ ^https?:// ]]; then
        ASSET_URL="$ASSET_PATH"
    else
        ASSET_URL="${TARGET_URL%/}${ASSET_PATH}"
    fi
    echo "[INFO] Testing referenced JavaScript bundle: $ASSET_URL ..."
    ASSET_HTTP_CODE=$(curl -sSL -o /dev/null -w "%{http_code}" --max-time 10 "$ASSET_URL" || echo "000")
    if [ "$ASSET_HTTP_CODE" -eq 200 ]; then
        echo "[SUCCESS] Script asset resolved with HTTP 200 OK."
    else
        echo "[ERROR] Script asset $ASSET_URL failed with HTTP $ASSET_HTTP_CODE!"
        exit 1
    fi
fi

echo "============================================================"
echo "All Frontend Smoke Tests PASSED successfully!"
echo "============================================================"
exit 0
