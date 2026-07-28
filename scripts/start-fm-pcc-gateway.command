#!/bin/zsh
set -euo pipefail

FM_HOST="${FM_HOST:-127.0.0.1}"
FM_PORT="${FM_PORT:-1976}"
GATEWAY_HOST="${GATEWAY_HOST:-0.0.0.0}"
GATEWAY_PORT="${GATEWAY_PORT:-1977}"
PCC_MODEL="${PCC_MODEL:-pcc}"

if [[ -z "${PCC_GATEWAY_TOKEN:-}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    PCC_GATEWAY_TOKEN="$(openssl rand -hex 24)"
  else
    PCC_GATEWAY_TOKEN="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  fi
fi

if ! command -v fm >/dev/null 2>&1; then
  echo "Error: fm command not found. Install/configure Foundation Models CLI first."
  exit 1
fi

LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "YOUR_MAC_IP")"
FM_BASE_URL="http://${FM_HOST}:${FM_PORT}"

cleanup() {
  if [[ -n "${FM_PID:-}" ]]; then
    kill "${FM_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

echo "Starting fm serve on ${FM_BASE_URL}..."
fm serve --host "${FM_HOST}" --port "${FM_PORT}" &
FM_PID="$!"

echo ""
echo "Apple PCC Gateway for Browser"
echo "URL for Simulator/Mac: http://127.0.0.1:${GATEWAY_PORT}"
echo "URL for iPhone/iPad:  http://${LAN_IP}:${GATEWAY_PORT}"
echo "Token: ${PCC_GATEWAY_TOKEN}"
echo ""
echo "In Browser Settings -> Apple PCC Gateway:"
echo "  Host: ${LAN_IP} (or 127.0.0.1 in Simulator)"
echo "  Port: ${GATEWAY_PORT}"
echo "  Token: ${PCC_GATEWAY_TOKEN}"
echo "  Model: ${PCC_MODEL}"
echo ""
echo "Health test:"
echo "  curl -H 'Authorization: Bearer ${PCC_GATEWAY_TOKEN}' http://127.0.0.1:${GATEWAY_PORT}/health"
echo ""

PCC_GATEWAY_TOKEN="${PCC_GATEWAY_TOKEN}" \
PCC_GATEWAY_HOST="${GATEWAY_HOST}" \
PCC_GATEWAY_PORT="${GATEWAY_PORT}" \
PCC_MODEL="${PCC_MODEL}" \
FM_BASE_URL="${FM_BASE_URL}" \
python3 -u <<'PY'
import json
import os
import subprocess
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ["PCC_GATEWAY_TOKEN"]
HOST = os.environ["PCC_GATEWAY_HOST"]
PORT = int(os.environ["PCC_GATEWAY_PORT"])
MODEL = os.environ["PCC_MODEL"]
FM_BASE_URL = os.environ["FM_BASE_URL"].rstrip("/")


def json_bytes(payload):
    return json.dumps(payload, separators=(",", ":")).encode("utf-8")


def read_fm_health():
    try:
        with urllib.request.urlopen(FM_BASE_URL + "/health", timeout=5) as response:
            raw = response.read().decode("utf-8", errors="replace")
            try:
                return "ok", json.loads(raw)
            except Exception:
                return "ok", raw
    except urllib.error.HTTPError as exc:
        return "error", exc.read().decode("utf-8", errors="replace")
    except Exception as exc:
        return "down", str(exc)


def model_available(health_payload):
    if isinstance(health_payload, dict):
        for model in health_payload.get("models", []):
            if model.get("name") == MODEL:
                return bool(model.get("available")), model.get("reason")
    return None, None


def cli_pcc_available():
    try:
        result = subprocess.run(
            ["fm", "available", "--model", MODEL],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
        )
    except Exception as exc:
        return False, str(exc)
    output = ((result.stdout or "") + "\n" + (result.stderr or "")).strip()
    if result.returncode == 0 and "available" in output.lower():
        return True, output
    return False, output or f"fm available exited with status {result.returncode}"


def message_content_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, dict):
                text = item.get("text") or item.get("content")
                if isinstance(text, str):
                    parts.append(text)
            elif isinstance(item, str):
                parts.append(item)
        return "\n".join(parts)
    return ""


def messages_to_prompt(messages):
    lines = []
    for message in messages if isinstance(messages, list) else []:
        if not isinstance(message, dict):
            continue
        role = str(message.get("role") or "user").upper()
        text = message_content_text(message.get("content")).strip()
        if text:
            lines.append(f"{role}:\n{text}")
    return "\n\n".join(lines).strip()


def completion_response(text):
    return {
        "id": "chatcmpl-" + uuid.uuid4().hex,
        "object": "chat.completion",
        "created": int(time.time()),
        "model": MODEL,
        "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": text},
            "finish_reason": "stop",
        }],
    }


def direct_fm_response(prompt):
    result = subprocess.run(
        ["fm", "respond", "--model", MODEL, "--no-stream"],
        input=prompt,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=300,
    )
    output = (result.stdout or "").strip()
    error = (result.stderr or "").strip()
    if result.returncode != 0:
        raise RuntimeError(error or output or f"fm respond exited with status {result.returncode}")
    if not output:
        raise RuntimeError(error or "fm respond returned an empty response.")
    return output


class GatewayHandler(BaseHTTPRequestHandler):
    server_version = "BrowserPCCGateway/1.0"

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args))

    def send_json(self, status, payload):
        body = json_bytes(payload)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        if self.headers.get("Authorization", "") != "Bearer " + TOKEN:
            self.send_json(401, {"error": {"type": "unauthorized", "message": "Missing or invalid Apple PCC Gateway token."}})
            return False
        return True

    def do_GET(self):
        if self.path != "/health":
            self.send_json(404, {"error": {"type": "not_found", "message": "Unknown endpoint."}})
            return
        if not self.authorized():
            return

        fm_status, fm_payload = read_fm_health()
        available, reason = model_available(fm_payload)
        cli_available = False
        cli_detail = None
        if available is not True:
            cli_available, cli_detail = cli_pcc_available()
            if cli_available:
                available = True
                reason = "PCC is available through the fm CLI direct fallback."

        status = "ok"
        http_status = 200
        if fm_status == "down" and not cli_available:
            status = "fm_down"
            http_status = 503
        elif available is False and not cli_available:
            status = "pcc_unavailable"
            http_status = 503

        self.send_json(http_status, {
            "proxy": "ok",
            "model": MODEL,
            "model_available": available,
            "reason": reason,
            "cli_available": cli_available,
            "cli_detail": cli_detail,
            "fm": {"status": fm_status, "health": fm_payload},
            "status": status,
        })

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_json(404, {"error": {"type": "not_found", "message": "Unknown endpoint."}})
            return
        if not self.authorized():
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)
            payload = json.loads(body.decode("utf-8"))
        except Exception as exc:
            self.send_json(400, {"error": {"type": "bad_request", "message": f"Invalid JSON: {exc}"}})
            return

        if payload.get("model", MODEL) != MODEL:
            self.send_json(400, {"error": {"type": "bad_model", "message": f"This gateway is configured for model '{MODEL}'."}})
            return
        if payload.get("stream") is True:
            self.send_json(400, {"error": {"type": "streaming_unsupported", "message": "Apple PCC Gateway is non-streaming for now."}})
            return

        prompt = messages_to_prompt(payload.get("messages"))
        if not prompt:
            self.send_json(400, {"error": {"type": "empty_prompt", "message": "No prompt content was provided."}})
            return

        upstream_body = ""
        try:
            request = urllib.request.Request(
                FM_BASE_URL + "/v1/chat/completions",
                data=json_bytes({"model": MODEL, "messages": payload.get("messages", []), "stream": False}),
                headers={"Content-Type": "application/json", "Accept": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(request, timeout=300) as response:
                response_body = response.read()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response_body)))
            self.end_headers()
            self.wfile.write(response_body)
            return
        except urllib.error.HTTPError as exc:
            upstream_body = exc.read().decode("utf-8", errors="replace")
            if exc.code not in (404, 503):
                self.send_json(exc.code, {"error": {"type": "fm_error", "message": upstream_body or str(exc)}})
                return
        except Exception as exc:
            upstream_body = str(exc)

        try:
            text = direct_fm_response(prompt)
            self.send_json(200, completion_response(text))
        except Exception as exc:
            self.send_json(503, {"error": {"type": "pcc_unavailable", "message": str(exc), "upstream": upstream_body}})


server = ThreadingHTTPServer((HOST, PORT), GatewayHandler)
print(f"Serving Apple PCC Gateway on http://{HOST}:{PORT}")
try:
    server.serve_forever()
finally:
    server.server_close()
PY
