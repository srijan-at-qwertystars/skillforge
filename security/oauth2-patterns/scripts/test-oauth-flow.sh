#!/usr/bin/env bash
# test-oauth-flow.sh — Test an OAuth2 authorization code flow end-to-end.
#
# Steps:
#   1. Generate PKCE verifier/challenge
#   2. Start a temporary local HTTP server to receive the callback
#   3. Open the authorization URL in the browser
#   4. Capture the authorization code from the callback
#   5. Exchange the code for tokens
#   6. Display the tokens (access token, refresh token, ID token)
#
# Usage:
#   ./test-oauth-flow.sh \
#     --auth-url https://auth.example.com/authorize \
#     --token-url https://auth.example.com/oauth/token \
#     --client-id YOUR_CLIENT_ID \
#     --redirect-uri http://localhost:8976/callback \
#     --scope "openid profile email"
#
# Optional flags:
#   --client-secret SECRET     Client secret for confidential clients
#   --port PORT                Local callback server port (default: 8976)
#   --no-browser               Print the auth URL instead of opening it
#   --extra-params "key=val&..." Additional authorization request parameters
#
# Requirements: curl, openssl, python3 (for callback server), jq (for output)

set -euo pipefail

# Defaults
CALLBACK_PORT=8976
OPEN_BROWSER=true
CLIENT_SECRET=""
EXTRA_PARAMS=""
SCOPES="openid profile email"
REDIRECT_URI=""

usage() {
  sed -n '2,/^$/s/^# \{0,1\}//p' "$0"
  exit 1
}

# Parse arguments
AUTH_URL=""
TOKEN_URL=""
CLIENT_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --auth-url)      AUTH_URL="$2"; shift 2 ;;
    --token-url)     TOKEN_URL="$2"; shift 2 ;;
    --client-id)     CLIENT_ID="$2"; shift 2 ;;
    --client-secret) CLIENT_SECRET="$2"; shift 2 ;;
    --redirect-uri)  REDIRECT_URI="$2"; shift 2 ;;
    --scope)         SCOPES="$2"; shift 2 ;;
    --port)          CALLBACK_PORT="$2"; shift 2 ;;
    --no-browser)    OPEN_BROWSER=false; shift ;;
    --extra-params)  EXTRA_PARAMS="$2"; shift 2 ;;
    --help|-h)       usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

# Validate required params
if [ -z "$AUTH_URL" ] || [ -z "$TOKEN_URL" ] || [ -z "$CLIENT_ID" ]; then
  echo "ERROR: --auth-url, --token-url, and --client-id are required." >&2
  usage
fi

if [ -z "$REDIRECT_URI" ]; then
  REDIRECT_URI="http://localhost:${CALLBACK_PORT}/callback"
fi

# Check dependencies
for cmd in curl openssl python3 jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not found in PATH." >&2
    exit 1
  fi
done

echo "=== OAuth 2.0 Authorization Code Flow Test ==="
echo ""

# Step 1: Generate PKCE
base64url_encode() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

CODE_VERIFIER=$(openssl rand 32 | base64url_encode)
CODE_CHALLENGE=$(printf '%s' "$CODE_VERIFIER" | openssl dgst -sha256 -binary | base64url_encode)
STATE=$(openssl rand 16 | base64url_encode)

echo "[1/5] PKCE generated"
echo "  Verifier:  ${CODE_VERIFIER:0:20}..."
echo "  Challenge: ${CODE_CHALLENGE:0:20}..."
echo "  State:     ${STATE:0:20}..."
echo ""

# Step 2: Build authorization URL
AUTH_REQUEST="${AUTH_URL}?response_type=code"
AUTH_REQUEST+="&client_id=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${CLIENT_ID}'))")"
AUTH_REQUEST+="&redirect_uri=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${REDIRECT_URI}'))")"
AUTH_REQUEST+="&scope=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${SCOPES}'))")"
AUTH_REQUEST+="&state=${STATE}"
AUTH_REQUEST+="&code_challenge=${CODE_CHALLENGE}"
AUTH_REQUEST+="&code_challenge_method=S256"

if [ -n "$EXTRA_PARAMS" ]; then
  AUTH_REQUEST+="&${EXTRA_PARAMS}"
fi

echo "[2/5] Authorization URL built"

# Step 3: Start callback server and open browser
CALLBACK_FIFO=$(mktemp -u)
mkfifo "$CALLBACK_FIFO"
trap 'rm -f "$CALLBACK_FIFO"' EXIT

# Python callback server that captures the authorization code
python3 -c "
import http.server
import urllib.parse
import sys
import os

class CallbackHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == '/callback':
            params = urllib.parse.parse_qs(parsed.query)
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()

            if 'error' in params:
                error = params['error'][0]
                desc = params.get('error_description', [''])[0]
                self.wfile.write(f'<h1>Authorization Failed</h1><p>{error}: {desc}</p>'.encode())
                with open('$CALLBACK_FIFO', 'w') as f:
                    f.write(f'ERROR:{error}:{desc}')
            elif 'code' in params:
                code = params['code'][0]
                state = params.get('state', [''])[0]
                self.wfile.write(b'<h1>Authorization Successful</h1><p>You can close this tab.</p>')
                with open('$CALLBACK_FIFO', 'w') as f:
                    f.write(f'CODE:{code}:{state}')
            else:
                self.wfile.write(b'<h1>Unexpected Response</h1>')
                with open('$CALLBACK_FIFO', 'w') as f:
                    f.write('ERROR:unknown:no code or error in callback')
        else:
            self.send_response(404)
            self.end_headers()
        # Shut down after handling callback
        import threading
        threading.Thread(target=self.server.shutdown).start()

    def log_message(self, format, *args):
        pass  # Suppress HTTP logs

server = http.server.HTTPServer(('127.0.0.1', $CALLBACK_PORT), CallbackHandler)
print(f'Callback server listening on http://127.0.0.1:$CALLBACK_PORT/callback', flush=True)
server.serve_forever()
" &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null; rm -f "$CALLBACK_FIFO"' EXIT

sleep 1

echo "[3/5] Callback server started on port $CALLBACK_PORT"
echo ""

if [ "$OPEN_BROWSER" = true ]; then
  echo "Opening browser..."
  if command -v xdg-open &>/dev/null; then
    xdg-open "$AUTH_REQUEST" 2>/dev/null || true
  elif command -v open &>/dev/null; then
    open "$AUTH_REQUEST" 2>/dev/null || true
  else
    echo "Could not detect browser. Open this URL manually:"
    echo ""
    echo "  $AUTH_REQUEST"
    echo ""
  fi
else
  echo "Open this URL in your browser:"
  echo ""
  echo "  $AUTH_REQUEST"
  echo ""
fi

echo "Waiting for callback..."
echo ""

# Step 4: Wait for the callback
CALLBACK_RESULT=$(cat "$CALLBACK_FIFO")

IFS=':' read -r RESULT_TYPE RESULT_VALUE RESULT_EXTRA <<< "$CALLBACK_RESULT"

if [ "$RESULT_TYPE" = "ERROR" ]; then
  echo "ERROR: Authorization failed: $RESULT_VALUE - $RESULT_EXTRA"
  exit 1
fi

AUTH_CODE="$RESULT_VALUE"
RETURNED_STATE="$RESULT_EXTRA"

# Validate state
if [ "$RETURNED_STATE" != "$STATE" ]; then
  echo "ERROR: State mismatch! Expected: $STATE, Got: $RETURNED_STATE"
  echo "This may indicate a CSRF attack."
  exit 1
fi

echo "[4/5] Authorization code received (state validated)"
echo "  Code: ${AUTH_CODE:0:20}..."
echo ""

# Step 5: Exchange code for tokens
echo "[5/5] Exchanging code for tokens..."
echo ""

TOKEN_PARAMS="grant_type=authorization_code"
TOKEN_PARAMS+="&code=${AUTH_CODE}"
TOKEN_PARAMS+="&redirect_uri=${REDIRECT_URI}"
TOKEN_PARAMS+="&client_id=${CLIENT_ID}"
TOKEN_PARAMS+="&code_verifier=${CODE_VERIFIER}"

CURL_ARGS=(-s -X POST "$TOKEN_URL" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Accept: application/json" \
  -d "$TOKEN_PARAMS")

if [ -n "$CLIENT_SECRET" ]; then
  CURL_ARGS+=(-u "${CLIENT_ID}:${CLIENT_SECRET}")
fi

TOKEN_RESPONSE=$(curl "${CURL_ARGS[@]}")

# Check for errors
if echo "$TOKEN_RESPONSE" | jq -e '.error' &>/dev/null; then
  echo "=== Token Exchange Failed ==="
  echo "$TOKEN_RESPONSE" | jq .
  exit 1
fi

echo "=== Token Response ==="
echo "$TOKEN_RESPONSE" | jq .
echo ""

# Decode tokens if they're JWTs
decode_jwt() {
  local token="$1"
  local label="$2"
  # Check if it looks like a JWT (3 dot-separated parts)
  if echo "$token" | grep -qE '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$'; then
    echo "=== Decoded $label (header) ==="
    echo "$token" | cut -d. -f1 | tr '_-' '/+' | base64 -d 2>/dev/null | jq . 2>/dev/null || echo "(decode failed)"
    echo ""
    echo "=== Decoded $label (payload) ==="
    echo "$token" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq . 2>/dev/null || echo "(decode failed)"
    echo ""
  fi
}

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty')
ID_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.id_token // empty')
REFRESH_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.refresh_token // empty')

if [ -n "$ACCESS_TOKEN" ]; then
  decode_jwt "$ACCESS_TOKEN" "Access Token"
fi

if [ -n "$ID_TOKEN" ]; then
  decode_jwt "$ID_TOKEN" "ID Token"
fi

if [ -n "$REFRESH_TOKEN" ]; then
  echo "=== Refresh Token ==="
  echo "  ${REFRESH_TOKEN:0:40}..."
  echo ""
fi

echo "=== Flow Complete ==="
echo "Access Token:  $([ -n "$ACCESS_TOKEN" ] && echo 'Yes' || echo 'No')"
echo "ID Token:      $([ -n "$ID_TOKEN" ] && echo 'Yes' || echo 'No')"
echo "Refresh Token: $([ -n "$REFRESH_TOKEN" ] && echo 'Yes' || echo 'No')"
echo "Expires In:    $(echo "$TOKEN_RESPONSE" | jq -r '.expires_in // "N/A"') seconds"
