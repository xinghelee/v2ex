#!/usr/bin/env python3
"""Gate a GitHub release on a publicly available TestFlight build."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import jwt
import yaml


API_ROOT = "https://api.appstoreconnect.apple.com"
READY_EXTERNAL_STATE = "IN_BETA_TESTING"


class AppStoreConnectError(RuntimeError):
    pass


class AppStoreConnectClient:
    def __init__(self, issuer_id: str, key_id: str, private_key: str) -> None:
        now = int(time.time())
        self.token = jwt.encode(
            {
                "iss": issuer_id,
                "iat": now,
                "exp": now + 15 * 60,
                "aud": "appstoreconnect-v1",
            },
            private_key,
            algorithm="ES256",
            headers={"kid": key_id},
        )

    def get(self, path_or_url: str, params: dict[str, str] | None = None) -> dict:
        url = path_or_url if path_or_url.startswith("https://") else API_ROOT + path_or_url
        if params:
            url += "?" + urllib.parse.urlencode(params)

        request = urllib.request.Request(
            url,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")
            raise AppStoreConnectError(f"GET {url} returned HTTP {error.code}: {detail}") from None
        except urllib.error.URLError as error:
            raise AppStoreConnectError(f"GET {url} failed: {error.reason}") from None

    def all(self, path: str, params: dict[str, str] | None = None) -> list[dict]:
        response = self.get(path, params)
        data = list(response.get("data", []))
        next_url = response.get("links", {}).get("next")
        while next_url:
            response = self.get(next_url)
            data.extend(response.get("data", []))
            next_url = response.get("links", {}).get("next")
        return data


def project_metadata(config_path: Path, target: str) -> tuple[str, str]:
    with config_path.open(encoding="utf-8") as file:
        config = yaml.safe_load(file)

    version = str(config["settings"]["base"]["MARKETING_VERSION"]).strip()
    bundle_id = str(config["targets"][target]["settings"]["base"]["PRODUCT_BUNDLE_IDENTIFIER"]).strip()
    if not re.fullmatch(r"\d+(?:\.\d+){1,3}", version):
        raise ValueError(f"MARKETING_VERSION must be numeric dotted notation, got {version!r}")
    if not re.fullmatch(r"[A-Za-z0-9.-]+", bundle_id):
        raise ValueError(f"invalid PRODUCT_BUNDLE_IDENTIFIER {bundle_id!r}")
    return version, bundle_id


def private_key_from_environment() -> str:
    value = os.environ.get("ASC_PRIVATE_KEY")
    if value:
        return value.replace("\\n", "\n")

    path = os.environ.get("ASC_PRIVATE_KEY_PATH") or os.environ.get("ASC_KEY_FILEPATH")
    if path:
        return Path(path).expanduser().read_text(encoding="utf-8")
    raise ValueError("ASC_PRIVATE_KEY is not configured")


def emit_output(name: str, value: str, output_path: str | None) -> None:
    if output_path:
        with open(output_path, "a", encoding="utf-8") as output:
            output.write(f"{name}={value}\n")


def evaluate(client: AppStoreConnectClient, version: str, bundle_id: str) -> dict[str, str]:
    apps = client.all("/v1/apps", {"filter[bundleId]": bundle_id, "limit": "1"})
    if not apps:
        return {"ready": "false", "reason": f"No App Store Connect app for {bundle_id}"}
    app_id = apps[0]["id"]

    builds = client.all(
        "/v1/builds",
        {
            "filter[app]": app_id,
            "filter[preReleaseVersion.version]": version,
            "filter[expired]": "false",
            "sort": "-uploadedDate",
            "limit": "1",
        },
    )
    if not builds:
        return {"ready": "false", "reason": f"TestFlight build {version} has not been uploaded"}

    build = builds[0]
    build_id = build["id"]
    build_number = build["attributes"]["version"]
    processing_state = build["attributes"]["processingState"]
    result = {
        "ready": "false",
        "build_id": build_id,
        "build_number": build_number,
        "processing_state": processing_state,
        "external_state": "unknown",
        "public_link": "",
    }
    if processing_state != "VALID":
        result["reason"] = f"TestFlight {version} ({build_number}) is {processing_state}"
        return result

    detail = client.get(f"/v1/builds/{build_id}/buildBetaDetail")["data"]["attributes"]
    external_state = detail.get("externalBuildState", "unknown")
    result["external_state"] = external_state
    if external_state != READY_EXTERNAL_STATE:
        result["reason"] = f"TestFlight {version} ({build_number}) external state is {external_state}"
        return result

    groups = client.all("/v1/betaGroups", {"filter[app]": app_id, "limit": "200"})
    public_groups = [group for group in groups if group.get("attributes", {}).get("publicLinkEnabled")]
    for group in public_groups:
        relationships = client.all(
            f"/v1/betaGroups/{group['id']}/relationships/builds",
            {"limit": "200"},
        )
        if any(item["id"] == build_id for item in relationships):
            result.update(
                ready="true",
                reason=f"TestFlight {version} ({build_number}) is available via the public group",
                public_link=group["attributes"].get("publicLink", ""),
            )
            return result

    result["reason"] = f"TestFlight {version} ({build_number}) is not attached to a public-link group"
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=Path("project.yml"))
    parser.add_argument("--target", default="V2EX")
    parser.add_argument("--version", help="Override MARKETING_VERSION for diagnostics")
    parser.add_argument("--metadata-only", action="store_true")
    args = parser.parse_args()

    try:
        configured_version, bundle_id = project_metadata(args.config, args.target)
        version = args.version or configured_version
        if not re.fullmatch(r"\d+(?:\.\d+){1,3}", version):
            raise ValueError(f"invalid version override {version!r}")

        output_path = os.environ.get("GITHUB_OUTPUT")
        emit_output("version", version, output_path)
        emit_output("tag", f"v{version}", output_path)
        emit_output("bundle_id", bundle_id, output_path)
        if args.metadata_only:
            print(f"Release target: v{version} [{bundle_id}]")
            return 0

        issuer_id = os.environ.get("ASC_ISSUER_ID")
        key_id = os.environ.get("ASC_KEY_ID")
        if not issuer_id or not key_id:
            raise ValueError("ASC_ISSUER_ID and ASC_KEY_ID are required")

        client = AppStoreConnectClient(issuer_id, key_id, private_key_from_environment())
        result = evaluate(client, version, bundle_id)
        for name, value in result.items():
            emit_output(name, value, output_path)
        print(result["reason"])

        summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary_path:
            with open(summary_path, "a", encoding="utf-8") as summary:
                summary.write("## TestFlight release gate\n\n")
                summary.write(f"- Version: `{version}`\n")
                summary.write(f"- Ready: `{result['ready']}`\n")
                summary.write(f"- Status: {result['reason']}\n")
        return 0
    except (AppStoreConnectError, KeyError, OSError, ValueError, yaml.YAMLError) as error:
        print(f"release gate failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
