import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest
import tempfile

ROOT = Path(__file__).resolve().parents[1]

class EdgeConfigurationTests(unittest.TestCase):
    def test_both_public_edges_overwrite_real_ip(self):
        caddy = os.environ.get("CADDY_BIN") or shutil.which("caddy")
        self.assertTrue(caddy or shutil.which("docker"), "Caddy binary or Docker required; set CADDY_BIN")
        for name in ("Caddyfile", "Caddyfile.ip"):
            with self.subTest(config=name):
                env = dict(os.environ, PUBLIC_HOST="example.test", CADDY_SITE_ADDRESS="example.test", EDGE_UPSTREAM="backend:8080")
                if caddy:
                    command = [caddy, "adapt", "--adapter", "caddyfile", "--config", str(ROOT / name)]
                else:
                    command = ["docker", "run", "--rm", "-v", f"{ROOT}:/project:ro", "-e", "PUBLIC_HOST=example.test", "-e", "CADDY_SITE_ADDRESS=example.test", "-e", "EDGE_UPSTREAM=backend:8080", "caddy:2-alpine", "caddy", "adapt", "--adapter", "caddyfile", "--config", f"/project/{name}"]
                result = subprocess.run(command, env=env, capture_output=True, check=True, text=True)
                config = json.loads(result.stdout)
                proxies = []
                hsts = []
                def visit(value):
                    if isinstance(value, dict):
                        for key, item in value.items():
                            if key.lower() == 'strict-transport-security':
                                hsts.extend(item if isinstance(item, list) else [item])
                        if value.get("handler") == "reverse_proxy":
                            proxies.append(value)
                        for item in value.values():
                            visit(item)
                    elif isinstance(value, list):
                        for item in value:
                            visit(item)
                visit(config)
                self.assertEqual(len(proxies), 2)
                self.assertIn('max-age=31536000; includeSubDomains', hsts)
                for proxy in proxies:
                    headers = proxy["headers"]["request"]["set"]
                    real_ip = next(value for key, value in headers.items() if key.lower() == "x-real-ip")
                    self.assertEqual(real_ip, ["{http.request.remote.host}"])

    def test_backend_http_cannot_bypass_the_public_edge(self):
        # Resolve env_file against an isolated project directory containing only
        # a dummy .env. This works across Compose versions and never reads an
        # operator's actual deployment credentials.
        with tempfile.TemporaryDirectory() as project:
            (Path(project) / ".env").write_text("", encoding="utf-8")
            result = subprocess.run(["docker", "compose", "--project-directory", project, "--project-name", "voxhold-edge-test", "--env-file", str(ROOT / ".env.example"), "-f", str(ROOT / "compose.yaml"), "config", "--format", "json"], capture_output=True, check=True, text=True)
        config = json.loads(result.stdout)
        backend = config["services"]["backend"]
        self.assertIn("8080", [str(port) for port in backend.get("expose", [])])
        self.assertTrue(all(port["protocol"] == "udp" and int(port["target"]) != 8080 for port in backend.get("ports", [])))
        self.assertFalse(config["services"]["frontend"].get("ports"))
        self.assertTrue(set(backend["networks"]) & set(config["services"]["caddy"]["networks"]))

if __name__ == "__main__":
    unittest.main()
