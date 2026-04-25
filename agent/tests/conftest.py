"""
Shared pytest fixtures.

We build a *test-only* FastAPI app that mounts only the payments router so
this suite runs even before main.py wires payments.router in (avoids the
shared-file edit while teammates' branches are in flight).

Required env vars (set dummy values so app.config doesn't SystemExit on import):
    ANTHROPIC_API_KEY, BUNQ_API_KEY, SUPABASE_URL,
    SUPABASE_SERVICE_ROLE_KEY, SUPABASE_JWT_SECRET
"""

import os

# Set dummies BEFORE importing anything that triggers app.config validation.
os.environ.setdefault("ANTHROPIC_API_KEY", "test")
os.environ.setdefault("BUNQ_API_KEY", "test")
os.environ.setdefault("SUPABASE_URL", "http://test")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test")
os.environ.setdefault("SUPABASE_JWT_SECRET", "test")

import pytest  # noqa: E402
from fastapi import FastAPI  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402


@pytest.fixture
def app() -> FastAPI:
    from app.routes import payments

    a = FastAPI()
    a.include_router(payments.router)
    return a


@pytest.fixture
def client(app) -> TestClient:
    return TestClient(app)
