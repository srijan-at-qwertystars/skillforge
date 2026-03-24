#!/usr/bin/env python3
"""
oauth2-test-flow.py — Test OAuth2 Authorization Code + PKCE flow locally

Starts a temporary HTTP server to handle the OAuth2 callback, opens the
browser for authorization, and displays the resulting tokens.

Usage:
    python3 oauth2-test-flow.py \\
        --client-id YOUR_CLIENT_ID \\
        --auth-url https://accounts.google.com/o/oauth2/v2/auth \\
        --token-url https://oauth2.googleapis.com/token \\
        --scope "openid profile email"

    # With client secret (confidential client):
    python3 oauth2-test-flow.py \\
        --client-id YOUR_CLIENT_ID \\
        --client-secret YOUR_SECRET \\
        --auth-url https://accounts.google.com/o/oauth2/v2/auth \\
        --token-url https://oauth2.googleapis.com/token \\
        --scope "openid profile email"

    # Custom port and extra params:
    python3 oauth2-test-flow.py \\
        --client-id YOUR_CLIENT_ID \\
        --auth-url https://auth.example.com/authorize \\
        --token-url https://auth.example.com/token \\
        --port 9090 \\
        --extra-params "audience=https://api.example.com"

Requirements: Python 3.7+ (no external dependencies)

What it does:
    1. Generates PKCE code_verifier and code_challenge
    2. Generates a random state parameter
    3. Starts a local HTTP server on the specified port
    4. Opens the authorization URL in the default browser
    5. Waits for the callback with the authorization code
    6. Exchanges the code for tokens
    7. Displays the tokens (and decodes JWT payloads if present)
"""

import argparse
import base64
import hashlib
import http.server
import json
import os
import secrets
import sys
import threading
import time
import urllib.parse
import urllib.request
import webbrowser


def generate_pkce():
    """Generate PKCE code_verifier and code_challenge (S256)."""
    code_verifier = secrets.token_urlsafe(96)[:128]
    digest = hashlib.sha256(code_verifier.encode("ascii")).digest()
    code_challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
    return code_verifier, code_challenge


def decode_jwt_payload(token):
    """Decode the payload of a JWT token (without verification)."""
    try:
        parts = token.split(".")
        if len(parts) < 2:
            return None
        payload = parts[1]
        # Add padding
        padding = 4 - len(payload) % 4
        if padding != 4:
            payload += "=" * padding
        decoded = base64.urlsafe_b64decode(payload)
        return json.loads(decoded)
    except Exception:
        return None


class CallbackHandler(http.server.BaseHTTPRequestHandler):
    """HTTP handler for the OAuth2 callback."""

    auth_code = None
    state_received = None
    error = None

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)

        if parsed.path != "/callback":
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"Not found. Waiting for /callback")
            return

        if "error" in params:
            CallbackHandler.error = params["error"][0]
            error_desc = params.get("error_description", [""])[0]
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(
                f"<h1>Authorization Failed</h1><p>{CallbackHandler.error}: {error_desc}</p>"
                "<p>You can close this window.</p>".encode()
            )
            return

        if "code" not in params:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"Missing authorization code")
            return

        CallbackHandler.auth_code = params["code"][0]
        CallbackHandler.state_received = params.get("state", [None])[0]

        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(
            b"<h1>Authorization Successful</h1>"
            b"<p>Authorization code received. You can close this window.</p>"
            b"<script>window.close();</script>"
        )

    def log_message(self, format, *args):
        """Suppress default HTTP logging."""
        pass


def exchange_code(token_url, client_id, client_secret, code, redirect_uri, code_verifier):
    """Exchange authorization code for tokens."""
    data = {
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": redirect_uri,
        "client_id": client_id,
        "code_verifier": code_verifier,
    }
    if client_secret:
        data["client_secret"] = client_secret

    encoded = urllib.parse.urlencode(data).encode("ascii")
    req = urllib.request.Request(
        token_url,
        data=encoded,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
        },
    )

    try:
        with urllib.request.urlopen(req) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8")
        print(f"\n❌ Token exchange failed (HTTP {e.code}):", file=sys.stderr)
        try:
            print(json.dumps(json.loads(error_body), indent=2), file=sys.stderr)
        except json.JSONDecodeError:
            print(error_body, file=sys.stderr)
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description="Test OAuth2 Authorization Code + PKCE flow locally",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--client-id", required=True, help="OAuth2 client ID")
    parser.add_argument("--client-secret", default=None, help="OAuth2 client secret (for confidential clients)")
    parser.add_argument("--auth-url", required=True, help="Authorization endpoint URL")
    parser.add_argument("--token-url", required=True, help="Token endpoint URL")
    parser.add_argument("--scope", default="openid profile email", help="Space-separated scopes (default: openid profile email)")
    parser.add_argument("--port", type=int, default=8080, help="Local callback port (default: 8080)")
    parser.add_argument("--extra-params", default="", help="Extra query params for auth request (key=value&key2=value2)")
    parser.add_argument("--no-browser", action="store_true", help="Don't open browser automatically")
    parser.add_argument("--timeout", type=int, default=120, help="Timeout in seconds (default: 120)")

    args = parser.parse_args()

    redirect_uri = f"http://localhost:{args.port}/callback"
    code_verifier, code_challenge = generate_pkce()
    state = secrets.token_urlsafe(32)

    # Build authorization URL
    auth_params = {
        "response_type": "code",
        "client_id": args.client_id,
        "redirect_uri": redirect_uri,
        "scope": args.scope,
        "state": state,
        "code_challenge": code_challenge,
        "code_challenge_method": "S256",
    }

    # Parse and add extra params
    if args.extra_params:
        for pair in args.extra_params.split("&"):
            if "=" in pair:
                k, v = pair.split("=", 1)
                auth_params[k] = v

    auth_url = f"{args.auth_url}?{urllib.parse.urlencode(auth_params)}"

    # Start callback server
    server = http.server.HTTPServer(("localhost", args.port), CallbackHandler)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()

    print(f"🔐 OAuth2 Authorization Code + PKCE Test Flow")
    print(f"{'=' * 50}")
    print(f"Client ID:     {args.client_id}")
    print(f"Auth URL:      {args.auth_url}")
    print(f"Token URL:     {args.token_url}")
    print(f"Redirect URI:  {redirect_uri}")
    print(f"Scopes:        {args.scope}")
    print(f"PKCE Method:   S256")
    print(f"{'=' * 50}")
    print()

    if args.no_browser:
        print(f"Open this URL in your browser:\n{auth_url}\n")
    else:
        print("Opening browser for authorization...")
        webbrowser.open(auth_url)
        print(f"If the browser didn't open, visit:\n{auth_url}\n")

    print(f"Waiting for callback on http://localhost:{args.port}/callback ...")
    print(f"(Timeout: {args.timeout}s)\n")

    # Wait for callback
    start_time = time.time()
    while (
        CallbackHandler.auth_code is None
        and CallbackHandler.error is None
        and time.time() - start_time < args.timeout
    ):
        time.sleep(0.5)

    server.shutdown()

    if CallbackHandler.error:
        print(f"❌ Authorization error: {CallbackHandler.error}")
        sys.exit(1)

    if CallbackHandler.auth_code is None:
        print("❌ Timeout waiting for authorization callback")
        sys.exit(1)

    # Verify state
    if CallbackHandler.state_received != state:
        print("❌ State mismatch — possible CSRF attack!")
        print(f"   Expected: {state}")
        print(f"   Received: {CallbackHandler.state_received}")
        sys.exit(1)

    print("✅ Authorization code received")
    print("🔄 Exchanging code for tokens...\n")

    # Exchange code for tokens
    tokens = exchange_code(
        args.token_url,
        args.client_id,
        args.client_secret,
        CallbackHandler.auth_code,
        redirect_uri,
        code_verifier,
    )

    print("✅ Token exchange successful!\n")
    print(f"{'=' * 50}")
    print("TOKEN RESPONSE")
    print(f"{'=' * 50}")

    for key, value in tokens.items():
        if key in ("access_token", "refresh_token", "id_token"):
            display = f"{str(value)[:50]}..." if len(str(value)) > 50 else value
            print(f"\n{key}: {display}")

            # Decode JWT payload if applicable
            if isinstance(value, str) and value.count(".") == 2:
                payload = decode_jwt_payload(value)
                if payload:
                    print(f"  Decoded {key} payload:")
                    print(f"  {json.dumps(payload, indent=4, default=str)}")
        else:
            print(f"\n{key}: {value}")

    print(f"\n{'=' * 50}")
    print("Full response (JSON):")
    print(json.dumps(tokens, indent=2, default=str))


if __name__ == "__main__":
    main()
