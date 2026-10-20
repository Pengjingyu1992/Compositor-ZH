"""Exercise the production live Host in an isolated signed sandbox app, through the real stdio proxy."""
import argparse
import base64
import hashlib
import hmac
import threading
import json
import os
from pathlib import Path
import plistlib
import select
import shutil
import signal
import socket
import struct
import subprocess
import tempfile
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("runner", type=Path, help="build/live-mcp-checks built by check-live-mcp-clt.zsh")
parser.add_argument("helper", type=Path, help="the built app's compositor-cli")
parser.add_argument("--schema", type=Path, help="Official 2026-07-28 schema.json; requires jsonschema")
args = parser.parse_args()
checks = 0
schema = json.loads(args.schema.read_text()) if args.schema else None

def validate_schema(name, value):
    if schema:
        import jsonschema
        jsonschema.Draft202012Validator({**schema, "$ref": "#/$defs/" + name}).validate(value)

RESULT_SCHEMAS = {"server/discover": "DiscoverResult", "tools/list": "ListToolsResult", "tools/call": "CallToolResult",
    "resources/list": "ListResourcesResult", "resources/read": "ReadResourceResult", "prompts/list": "ListPromptsResult", "prompts/get": "GetPromptResult"}

def check(label, condition):
    global checks
    checks += 1
    if not condition:
        raise AssertionError(label)

class Client:
    def __init__(self, config):
        self.process = subprocess.Popen([str(args.helper.resolve()), "mcp", "--live", "--config", str(config)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.buffer = b""
        self.next_id = 1
        self.notifications = []
    def send(self, value):
        self.process.stdin.write(json.dumps(value).encode() + b"\n")
        self.process.stdin.flush()
    def read(self, timeout=15):
        until = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            remaining = until - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], max(0, remaining))[0]:
                raise TimeoutError("Live response timed out")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError("Live helper disconnected: " + self.process.stderr.read().decode(errors="replace"))
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)
    def rpc(self, method, params=None, modern=False):
        ident = self.next_id
        self.next_id += 1
        params = dict(params or {})
        if modern:
            params["_meta"] = {"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {}}
        self.send({"jsonrpc": "2.0", "id": ident, "method": method, "params": params})
        while True:
            value = self.read()
            if value.get("id") == ident:
                if (modern or method == "server/discover") and "result" in value and method in RESULT_SCHEMAS:
                    validate_schema(RESULT_SCHEMAS[method], value["result"])
                return value
            self.notifications.append(value)
    def tool(self, name, arguments=None, modern=False):
        response = self.rpc("tools/call", {"name": name, "arguments": arguments or {}}, modern)
        check("tool protocol response: " + name, "result" in response)
        result = response["result"]
        check("tool succeeded: " + name, not result.get("isError"))
        return result.get("structuredContent", {}), result
    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=5)

clients = []
container = None
host_pid = None
launcher = None
with tempfile.TemporaryDirectory(prefix="compositor-mcp-wire-") as temporary:
    directory = Path(temporary)
    app = directory / "Live MCP Fixture.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    executable = app / "Contents/MacOS/Fixture"
    shutil.copy2(args.runner.resolve(), executable)
    identity = "compositor.livecheck." + uuid.uuid4().hex[:8]
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identity, "CFBundleExecutable": "Fixture", "CFBundleName": "Live MCP Fixture", "CFBundlePackageType": "APPL", "LSBackgroundOnly": True}))
    entitlement = directory / "sandbox.plist"
    entitlement.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True, "com.apple.security.files.user-selected.read-write": True, "com.apple.security.files.bookmarks.app-scope": True}))
    subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", str(entitlement), str(app)], check=True, capture_output=True)
    container = Path.home() / "Library/Containers" / identity
    root = container / "Data/.mcp-live"
    try:
        launcher = subprocess.Popen(["open", "-W", "-n", str(app), "--args", "--serve"], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 30
        metadata_path = root / "fixture.json"
        while not metadata_path.exists() and time.monotonic() < deadline:
            if launcher.poll() is not None:
                raise RuntimeError("Sandbox fixture exited: " + launcher.stderr.read().decode(errors="replace"))
            time.sleep(0.1)
        check("signed sandbox host starts", metadata_path.exists())
        metadata = json.loads(metadata_path.read_text())
        host_pid = metadata["pid"]
        config = Path(metadata["config"])
        check("credential is private", config.stat().st_mode & 0o777 == 0o600)
        check("socket is private", Path(metadata["socket"]).stat().st_mode & 0o777 == 0o600)
        # A copied configuration with an invalid proof never reaches protocol routing or prompts.
        bad = directory / "bad-client.json"
        fields = json.loads(config.read_text()); fields["secret"] = base64.b64encode(bytes(32)).decode()
        bad.write_text(json.dumps(fields)); bad.chmod(0o600)
        denied = subprocess.run([str(args.helper.resolve()), "mcp", "--live", "--config", str(bad)], input=b'{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n', capture_output=True, timeout=15)
        check("wrong credential rejected without document disclosure", denied.returncode != 0 and not denied.stdout)
        anonymous = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); anonymous.settimeout(5)
        anonymous.connect(metadata["socket"]); anonymous.recv(8192)
        anonymous.sendall(b'{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n')
        check("unauthenticated RPC rejected", anonymous.recv(8192) == b""); anonymous.close()
        # A recorded server proof cannot authenticate a later helper with a fresh client nonce.
        original_config = json.loads(config.read_text())
        raw_peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); raw_peer.settimeout(5); raw_peer.connect(metadata["socket"])
        channel = raw_peer.makefile("rwb", buffering=0)
        old_challenge = json.loads(channel.readline())
        client_nonce = str(uuid.uuid4())
        binding = old_challenge["challenge"] + "\n" + client_nonce
        transcript = "Compositor-live-v1\nclient\n" + old_challenge["instance"] + "\n" + binding
        proof = base64.b64encode(hmac.new(base64.b64decode(original_config["secret"]), transcript.encode(), hashlib.sha256).digest()).decode()
        channel.write(json.dumps({"clientID": original_config["clientID"], "clientNonce": client_nonce, "proof": proof}).encode() + b"\n")
        old_server_proof = json.loads(channel.readline())
        channel.close(); raw_peer.close()
        fake_path = directory / "fake.sock"
        fake = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); fake.bind(str(fake_path)); fake.listen(1); fake.settimeout(10); fake_path.chmod(0o600)
        def replay_server():
            peer, _ = fake.accept()
            with peer:
                stream = peer.makefile("rwb", buffering=0)
                stream.write(json.dumps(old_challenge).encode() + b"\n")
                stream.readline()
                stream.write(json.dumps(old_server_proof).encode() + b"\n")
                stream.close()
        replay_thread = threading.Thread(target=replay_server, daemon=True); replay_thread.start()
        replay_config = directory / "replay-client.json"
        replay_config.write_text(json.dumps({**original_config, "socket": str(fake_path)})); replay_config.chmod(0o600)
        replayed = subprocess.run([str(args.helper.resolve()), "mcp", "--live", "--config", str(replay_config)], input=b"", capture_output=True, timeout=15)
        replay_thread.join(timeout=5); fake.close()
        check("replayed host proof is rejected", replayed.returncode != 0 and not replayed.stdout)
        legacy = Client(config); clients.append(legacy)
        initialized = legacy.rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "forged-display-only", "version": "1"}})
        check("legacy handshake", initialized["result"]["protocolVersion"] == "2025-11-25")
        legacy.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        tools = legacy.rpc("tools/list")["result"]["tools"]
        check("live tools plus aliases", len(tools) == 25 and {"project_state", "render_preview", "execute_commands", "save_document"} <= {tool["name"] for tool in tools})
        caps, _ = legacy.tool("get_capabilities")
        listed, _ = legacy.tool("list_documents")
        check("only approved instance is listed", len(listed["documents"]) == 1)
        handle = listed["documents"][0]["handle"]
        state, _ = legacy.tool("project_state", {"handle": handle})
        preview, preview_result = legacy.tool("render_preview", {"handle": handle, "longSide": 256})
        png = base64.b64decode(preview_result["content"][0]["data"])
        check("preview contains PNG and coherent tokens", png[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", png[16:24]) == (64, 48) and preview["state"]["changeToken"] == state["changeToken"])
        modern = Client(config); clients.append(modern)
        discovery = modern.rpc("server/discover")["result"]
        check("modern discovery has cache fields", discovery["resultType"] == "complete" and discovery["ttlMs"] == 0 and discovery["cacheScope"] == "private")
        modern_tools = modern.rpc("tools/list", modern=True)["result"]
        check("modern response metadata", "io.modelcontextprotocol/serverInfo" in modern_tools["_meta"])
        check("modern schemas match legacy", modern_tools["tools"] == tools)
        bad_version = modern.rpc("tools/list", {"_meta": {"io.modelcontextprotocol/protocolVersion": "1900-01-01", "io.modelcontextprotocol/clientCapabilities": {}}})
        check("unknown version uses protocol error", bad_version["error"]["code"] == -32022)
        bad_args = modern.rpc("tools/call", {"name": "render_preview", "arguments": {"handle": handle, "longSide": 9000}}, modern=True)
        check("invalid value is protocol argument error", bad_args["error"]["code"] == -32602)
        resources = modern.rpc("resources/list", modern=True)["result"]
        check("resource list is private and complete", resources["cacheScope"] == "private" and len(resources["resources"]) == 1)
        uri = resources["resources"][0]["uri"]
        resource = modern.rpc("resources/read", {"uri": uri}, modern=True)["result"]
        check("resource state matches document", json.loads(resource["contents"][0]["text"])["handle"] == handle)
        prompts = modern.rpc("prompts/list", modern=True)["result"]
        check("fixed prompts are available", len(prompts["prompts"]) == 2)
        prompt = modern.rpc("prompts/get", {"name": "poster_brief", "arguments": {"brief": "Synthetic pink poster"}}, modern=True)
        check("prompt uses supplied brief without executing it", "Synthetic pink poster" in prompt["result"]["messages"][0]["content"]["text"])
        subscription_id = "synthetic-subscription"
        modern.send({"jsonrpc": "2.0", "id": subscription_id, "method": "subscriptions/listen", "params": {"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {}}, "notifications": {"resourceSubscriptions": [uri], "resourcesListChanged": True}}})
        acknowledged = modern.read()
        validate_schema("SubscriptionsAcknowledgedNotification", acknowledged)
        check("subscription acknowledged before updates", acknowledged.get("method") == "notifications/subscriptions/acknowledged" and acknowledged["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"] == subscription_id)
        def guarded(source, extra=None):
            return {"handle": source["handle"], "expectedRevision": source["revision"], "expectedChangeToken": source["changeToken"], "expectedLockRevision": source["lockRevision"], "operationID": caps["operationPrefix"] + str(uuid.uuid4()), **(extra or {})}
        layer_id = state["layers"][0]["id"]
        arguments = guarded(state, {"documentID": state["documentID"], "commands": [{"kind": "opacity", "layerID": layer_id, "opacity": 0.4}]})
        changed, _ = legacy.tool("execute_commands", arguments)
        check("wire edit commits", changed["status"] == "changed")
        updated = modern.read()
        validate_schema("ResourceUpdatedNotification", updated)
        check("modern resource update is scoped", updated.get("method") == "notifications/resources/updated" and updated["params"]["uri"] == uri and updated["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"] == subscription_id)
        duplicate, _ = legacy.tool("execute_commands", arguments)
        check("wire retry replays same receipt", duplicate == changed)
        receipt, _ = modern.tool("get_operation_result", {"operationID": arguments["operationID"]}, modern=True)
        check("receipt query matches", receipt == changed)
        new_state, _ = modern.tool("get_document", {"handle": handle}, modern=True)
        save, _ = legacy.tool("save_document", guarded(new_state, {"name": "wire-copy.comp"}))
        check("sandbox copy is written", (Path(metadata["output"]) / save["outputName"] / "manifest.json").is_file())
        exported, _ = modern.tool("export_document", guarded(new_state, {"name": "wire.png"}), modern=True)
        check("sandbox PNG is written", (Path(metadata["output"]) / exported["outputName"]).read_bytes()[:8] == png[:8])
        overwrite = legacy.rpc("tools/call", {"name": "save_document", "arguments": guarded(new_state, {"name": "wire-copy.comp"})})
        check("wire overwrite returns tool failure", overwrite["result"]["isError"])
        modern.send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": subscription_id, "reason": "Synthetic test complete"}})
        ended = modern.read()
        validate_schema("SubscriptionsListenResult", ended["result"])
        check("subscription ends with matching result metadata", ended["id"] == subscription_id and ended["result"]["_meta"]["io.modelcontextprotocol/subscriptionId"] == subscription_id)
        print(f"Signed sandbox live MCP / stdio: {checks} checks, 0 failures")
    finally:
        for client in clients:
            client.close()
        if root.exists():
            (root / "stop").touch()
        if launcher:
            try:
                launcher.wait(timeout=10)
            except subprocess.TimeoutExpired:
                if host_pid:
                    os.kill(host_pid, signal.SIGTERM)
                launcher.wait(timeout=5)
        if container and container.name.startswith("compositor.livecheck."):
            shutil.rmtree(container, ignore_errors=True)
