import shlex
from urllib.parse import urlparse

from pyinfra import host
from pyinfra.operations import server


component = host.data.component
health_url = host.data.health_url

if component not in {"gateway", "wirekeeper", "engine"}:
    raise ValueError("component must be gateway, wirekeeper, or engine")

try:
    parsed_health_url = urlparse(health_url)
    health_port = parsed_health_url.port
except ValueError as error:
    raise ValueError("health_url must use loopback HTTP with a valid port") from error

if (
    parsed_health_url.scheme != "http"
    or parsed_health_url.hostname != "127.0.0.1"
    or parsed_health_url.username is not None
    or parsed_health_url.password is not None
    or health_port is None
    or not 1 <= health_port <= 65_535
    or not parsed_health_url.path.startswith("/")
    or parsed_health_url.fragment
    or any(character.isspace() for character in health_url)
):
    raise ValueError("health_url must use loopback HTTP")

server.shell(
    name=f"Roll back the {component} release",
    commands=" ".join(
        shlex.quote(argument)
        for argument in [
            "/usr/local/sbin/topics-club-deploy",
            "rollback",
            component,
            health_url,
        ]
    ),
)
