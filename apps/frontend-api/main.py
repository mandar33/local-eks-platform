import os

import httpx
from fastapi import FastAPI

app = FastAPI()

FLIPT_URL = os.getenv("FLIPT_URL", "http://flipt.default.svc.cluster.local:8080")
CRUD_API_URL = os.getenv("CRUD_API_URL", "http://crud-api-svc.default.svc.cluster.local")
FLIPT_NAMESPACE = os.getenv("FLIPT_NAMESPACE", "default")
# Set by the Helm chart from the pod's `version` label (v1 stable, v2 canary).
APP_VERSION = os.getenv("APP_VERSION", "unknown")


@app.middleware("http")
async def add_version_header(request, call_next):
    response = await call_next(request)
    response.headers["x-app-version"] = APP_VERSION
    return response


async def is_feature_enabled(flag_key: str, user_id: str) -> bool:
    async with httpx.AsyncClient() as client:
        try:
            response = await client.post(
                f"{FLIPT_URL}/evaluate/v1/boolean",
                json={
                    "namespaceKey": FLIPT_NAMESPACE,
                    "flagKey": flag_key,
                    "entityId": user_id,
                    "context": {},
                },
            )
            if response.status_code == 200:
                return response.json().get("enabled", False)
        except Exception:
            pass
    return False


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.get("/users/{user_id}")
async def fetch_user_data(user_id: str):
    use_new_schema = await is_feature_enabled("enable-new-schema", user_id)

    async with httpx.AsyncClient() as client:
        if use_new_schema:
            response = await client.get(f"{CRUD_API_URL}/api/v2/users/{user_id}")
        else:
            response = await client.get(f"{CRUD_API_URL}/api/v1/users/{user_id}")

    return response.json()
