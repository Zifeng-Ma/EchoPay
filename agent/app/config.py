"""
EchoPay Agent configuration.

Loads from environment via python-dotenv. Only keys required by active routes
are enforced at startup so local demos are not blocked by unrelated services.
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


def _optional(name: str) -> str | None:
    """Return the env var value when present, otherwise None."""
    value = os.environ.get(name)
    return value or None


class Settings:
    """All configuration for the EchoPay agent service."""

    # --- OpenAI ---
    openai_api_key: str
    openai_order_model: str
    openai_transcription_model: str
    openai_diarization_model: str
    openai_tts_model: str
    openai_tts_voice: str

    # --- Anthropic ---
    anthropic_api_key: str | None

    # --- bunq ---
    bunq_api_key: str | None
    bunq_use_sandbox: bool

    # --- Supabase (backend service-role — full DB access) ---
    supabase_url: str | None
    supabase_service_role_key: str | None
    supabase_jwt_secret: str | None

    # --- Optional (filled after Plan 05 Edge Function deploy) ---
    bunq_webhook_url: str | None

    def __init__(self) -> None:
        self.openai_api_key = _require("OPENAI_API_KEY")
        self.openai_order_model = os.environ.get("OPENAI_ORDER_MODEL", "gpt-4o-mini")
        self.openai_transcription_model = os.environ.get(
            "OPENAI_TRANSCRIPTION_MODEL",
            "gpt-4o-mini-transcribe",
        )
        self.openai_diarization_model = os.environ.get(
            "OPENAI_DIARIZATION_MODEL",
            "gpt-4o-transcribe-diarize",
        )
        self.openai_tts_model = os.environ.get("OPENAI_TTS_MODEL", "gpt-4o-mini-tts")
        self.openai_tts_voice = os.environ.get("OPENAI_TTS_VOICE", "coral")
        self.anthropic_api_key = _optional("ANTHROPIC_API_KEY")
        self.bunq_api_key = _optional("BUNQ_API_KEY")
        self.bunq_use_sandbox = os.environ.get("BUNQ_USE_SANDBOX", "true").lower() == "true"
        self.supabase_url = _optional("SUPABASE_URL")
        self.supabase_service_role_key = _optional("SUPABASE_SERVICE_ROLE_KEY")
        self.supabase_jwt_secret = _optional("SUPABASE_JWT_SECRET")
        self.bunq_webhook_url = _optional("BUNQ_WEBHOOK_URL")


# Module-level singleton — instantiated at import time so missing vars fail fast.
# main.py imports this to trigger validation before the server starts accepting traffic.
try:
    settings = Settings()
except ValueError as exc:
    # Re-raise with a clear prefix so it appears in uvicorn startup logs
    raise SystemExit(str(exc)) from exc
