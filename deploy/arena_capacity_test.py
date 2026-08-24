#!/usr/bin/env python3
"""Keep the reference fleet large enough to serve every declared zone."""

import re
import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def check(ok: bool, message: str) -> None:
    if not ok:
        raise SystemExit(f"FAIL {message}")
    print(f"ok   {message}")


catalog = tomllib.loads((ROOT / "catalog/catalog.toml").read_text())
zones = [zone["name"] for zone in catalog.get("zone", [])]
check(bool(zones), "the catalog declares at least one zone")

compose = (ROOT / "deploy/docker-compose.arena.yml").read_text()
services = compose.split("\nservices:\n", 1)[1].split("\nvolumes:\n", 1)[0]
volumes = compose.split("\nvolumes:\n", 1)[1]
arenas = sorted({int(n) for n in re.findall(r"^  a(\d+):$", services, re.M)})
expected = list(range(1, len(zones) + 1))
check(
    arenas == expected,
    f"{len(zones)} catalog zones have {len(arenas)} arena processes",
)

for number in expected:
    socket_port = 9000 + number
    metrics_port = 9100 + number
    quic_port = 9442 + number
    name = f"a{number}"
    service_match = re.search(
        rf"^  {name}:\n(.*?)(?=^  [a-zA-Z0-9_-]+:\n|\Z)", services, re.M | re.S
    )
    service = service_match.group(1) if service_match else ""
    required = [
        f'command: ["127.0.0.1:{socket_port}", "/var/lib/vectorwake"]',
        f"VW_ADDRESS: wss://${{VW_HOST:?set VW_HOST}}/{name}",
        f"VW_WT_LISTEN: 0.0.0.0:{quic_port}",
        f"VW_WT_ADDRESS: https://${{VW_HOST}}:{quic_port}/{name}",
        f"VW_METRICS: 127.0.0.1:{metrics_port}",
        f"- {name}:/var/lib/vectorwake",
    ]
    check(
        bool(service) and all(piece in service for piece in required),
        f"{name} has its socket, metrics, QUIC, address, and state",
    )
    check(re.search(rf"^  {name}:$", volumes, re.M) is not None, f"{name} has a volume")

local = (ROOT / "deploy/docker-compose.local.yml").read_text()
local_services = local.split("\nservices:\n", 1)[1].split("\nvolumes:\n", 1)[0]
for number in expected:
    name = f"a{number}"
    service_match = re.search(
        rf"^  {name}:\n(.*?)(?=^  [a-zA-Z0-9_-]+:\n|\Z)",
        local_services,
        re.M | re.S,
    )
    service = service_match.group(1) if service_match else ""
    check("<<: *build" in service, f"the local overlay builds {name} from this checkout")

targets = re.search(r"^\s+VW_ARENAS:\s*(\S+)\s*$", services, re.M)
wanted_targets = ",".join(f"ws://127.0.0.1:{9000 + n}" for n in expected)
check(targets is not None and targets.group(1) == wanted_targets, "bots dial every arena")

dependencies = re.search(r"^\s+depends_on:\s*\[([^]]*)\]\s*$", services, re.M)
wanted_dependencies = [f"a{n}" for n in expected]
have_dependencies = (
    [part.strip() for part in dependencies.group(1).split(",")]
    if dependencies
    else []
)
check(have_dependencies == wanted_dependencies, "bots wait for every arena")

caddy = (ROOT / "deploy/caddy/conf.d/arena.caddy").read_text()
socket_routes = sorted({int(n) for n in re.findall(r"handle_path /a(\d+)\*", caddy)})
metrics_routes = sorted({int(n) for n in re.findall(r"handle /metrics/a(\d+)\*", caddy)})
check(socket_routes == expected, "Caddy exposes every arena socket")
check(metrics_routes == expected, "Caddy exposes every arena metric")

caddy_compose = (ROOT / "deploy/docker-compose.caddy.yml").read_text()
route_label = re.search(r"^\s+vw\.routes:\s*(.+?)\s*$", caddy_compose, re.M)
label_routes = route_label.group(1).split() if route_label else []
check(
    all(f"a{number}" in label_routes for number in expected),
    "the Caddy service label tracks every arena route",
)
for number in expected:
    socket = re.search(
        rf"handle_path /a{number}\* \{{(.*?)^\}}", caddy, re.M | re.S
    )
    metric = re.search(
        rf"handle /metrics/a{number}\* \{{(.*?)^\}}", caddy, re.M | re.S
    )
    check(
        socket is not None
        and f"reverse_proxy 127.0.0.1:{9000 + number}" in socket.group(1)
        and metric is not None
        and f"reverse_proxy 127.0.0.1:{9100 + number}" in metric.group(1),
        f"a{number} routes reach the matching ports",
    )

first_quic = 9443
last_quic = 9442 + len(expected)
ufw_port = str(first_quic) if first_quic == last_quic else f"{first_quic}:{last_quic}"
provision = (ROOT / "deploy/provision.sh").read_text()
check(f"ufw allow {ufw_port}/udp" in provision, "new hosts open every QUIC port")

fleet_paths = [ROOT / "deploy/fleet.sh"]
fleet_paths.extend(sorted((ROOT / "deploy/lib").glob("fleet_*.sh")))
fleet = "\n".join(path.read_text() for path in fleet_paths)
rules = re.search(r'^FW_RULES="([^"]+)"$', fleet, re.M)
check(
    rules is not None and f"udp:{ufw_port}" in rules.group(1).split(),
    "the provider firewall opens every QUIC port",
)

print(f"arena capacity checks passed for {len(zones)} zone(s): {', '.join(zones)}")
