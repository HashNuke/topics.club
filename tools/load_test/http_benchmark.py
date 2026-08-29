#!/usr/bin/env python3
"""Benchmark the local combined app through its real cookie authentication flow."""

from __future__ import annotations

import concurrent.futures
import http.cookiejar
import json
import math
import os
import re
import statistics
import time
import urllib.error
import urllib.parse
import urllib.request


BASE_URL = os.environ["LOAD_BASE_URL"].rstrip("/")
MAGIC_TOKEN = os.environ["LOAD_MAGIC_TOKEN"]
REQUESTS = int(os.environ.get("LOAD_HTTP_REQUESTS", "200"))
CONCURRENCY = int(os.environ.get("LOAD_HTTP_CONCURRENCY", "20"))
FORWARDED_HEADERS = {"x-forwarded-proto": "https"}


def request(path: str, *, cookie: str | None = None) -> tuple[int, bytes]:
    headers = dict(FORWARDED_HEADERS)
    if cookie:
        headers["cookie"] = cookie
    req = urllib.request.Request(f"{BASE_URL}{path}", headers=headers)
    with urllib.request.urlopen(req, timeout=30) as response:
        return response.status, response.read()


def authenticate() -> str:
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    confirmation = urllib.request.Request(
        f"{BASE_URL}/users/log-in/{urllib.parse.quote(MAGIC_TOKEN)}",
        headers=FORWARDED_HEADERS,
    )
    with opener.open(confirmation, timeout=30) as response:
        html = response.read().decode()

    match = re.search(r'name="_csrf_token"[^>]*value="([^"]+)"', html)
    if not match:
        raise RuntimeError("login confirmation did not contain a CSRF token")

    # Phoenix correctly marks its production session cookie Secure. The lab's
    # traffic is plain HTTP inside an isolated Docker network with
    # x-forwarded-proto=https, so CookieJar will store but not resend it.
    confirmation_cookie = "; ".join(f"{item.name}={item.value}" for item in jar)

    body = urllib.parse.urlencode(
        {"_csrf_token": match.group(1), "user[token]": MAGIC_TOKEN}
    ).encode()
    login = urllib.request.Request(
        f"{BASE_URL}/users/log-in",
        data=body,
        headers={
            **FORWARDED_HEADERS,
            "cookie": confirmation_cookie,
            "content-type": "application/x-www-form-urlencoded",
        },
    )
    with opener.open(login, timeout=30) as response:
        response.read()
        if response.status != 200:
            raise RuntimeError(f"login ended at {response.status} {response.url}")

    cookie = "; ".join(f"{item.name}={item.value}" for item in jar)
    if "_topics_club_key=" not in cookie:
        raise RuntimeError("login did not issue the application session cookie")
    return cookie


def percentile(values: list[float], fraction: float) -> float:
    index = max(0, math.ceil(len(values) * fraction) - 1)
    return sorted(values)[index]


def benchmark(path: str, *, cookie: str | None = None) -> dict[str, float | int]:
    def one(_sequence: int) -> tuple[float, int]:
        started = time.perf_counter()
        try:
            status, _body = request(path, cookie=cookie)
        except urllib.error.HTTPError as error:
            status = error.code
        except Exception:
            status = 0
        return (time.perf_counter() - started) * 1_000, status

    started = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=CONCURRENCY) as executor:
        results = list(executor.map(one, range(REQUESTS)))
    elapsed = time.perf_counter() - started

    latencies = [latency for latency, _status in results]
    errors = sum(status != 200 for _latency, status in results)
    return {
        "requests": REQUESTS,
        "concurrency": CONCURRENCY,
        "errors": errors,
        "elapsed_seconds": round(elapsed, 3),
        "requests_per_second": round(REQUESTS / elapsed, 2),
        "mean_ms": round(statistics.mean(latencies), 2),
        "p50_ms": round(percentile(latencies, 0.50), 2),
        "p95_ms": round(percentile(latencies, 0.95), 2),
        "p99_ms": round(percentile(latencies, 0.99), 2),
        "max_ms": round(max(latencies), 2),
    }


def main() -> None:
    cookie = authenticate()
    status, payload = request("/api/bootstrap", cookie=cookie)
    bootstrap = json.loads(payload)
    if status != 200 or len(bootstrap.get("connections", [])) != 1:
        raise RuntimeError("authenticated bootstrap validation failed")

    result = {
        "health": benchmark("/health"),
        "bootstrap": benchmark("/api/bootstrap", cookie=cookie),
    }
    print("LOAD_HTTP_JSON=" + json.dumps(result, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
