"""
EchoPay Agent configuration.

Loads from environment via python-dotenv. Required vars are validated at
module import time — a missing var raises ValueError with the exact var name,
catching "forgot to copy .env.example → .env" errors at boot, not at runtime.
"""

import os
from dotenv import load_dotenv

# Load .env from the agent/ directory (where uvicorn is invoked from)
load_dotenv()


def _require(name: str) -> str:
    """Return the env var value or raise a descriptive error."""
    value = os.environ.get(name)
    if not value:
        raise ValueError(
            f"[EchoPay Config] Required environment variable '{name}' is missing or empty.\n"
            f"  → Copy agent/.env.example to agent/.env and fill it in."
        )
    return value


class Settings:
    """All configuration for the EchoPay agent service."""

    # --- Anthropic ---
    anthropic_api_key: str

    # --- bunq ---
    bunq_api_key: str

    # --- Supabase (backend service-role — full DB access) ---
    supabase_url: str
    supabase_service_role_key: str
    supabase_jwt_secret: str

    # --- Optional (filled after Plan 05 Edge Function deploy) ---
    bunq_webhook_url: str | None

    def __init__(self) -> None:
        self.anthropic_api_key = _require("ANTHROPIC_API_KEY")
        self.bunq_api_key = _require("BUNQ_API_KEY")
        self.supabase_url = _require("SUPABASE_URL")
        self.supabase_service_role_key = _require("SUPABASE_SERVICE_ROLE_KEY")
        self.supabase_jwt_secret = _require("SUPABASE_JWT_SECRET")
        self.bunq_webhook_url = os.environ.get("BUNQ_WEBHOOK_URL")


# Module-level singleton — instantiated at import time so missing vars fail fast.
# main.py imports this to trigger validation before the server starts accepting traffic.
try:
    settings = Settings()
except ValueError as exc:
    # Re-raise with a clear prefix so it appears in uvicorn startup logs
    raise SystemExit(str(exc)) from exc
