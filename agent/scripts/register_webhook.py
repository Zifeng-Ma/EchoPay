"""
Register bunq notification callbacks → BUNQ_WEBHOOK_URL.

Run after starting ngrok and setting BUNQ_WEBHOOK_URL in agent/.env, e.g.:
    ngrok http 8000
    # paste https://abc123.ngrok.io/payments/webhook into agent/.env
    cd agent
    python -m scripts.register_webhook
"""

from app.config import settings
from app.services import bunq_service


def main() -> None:
    if not settings.bunq_webhook_url:
        raise SystemExit(
            "Set BUNQ_WEBHOOK_URL in agent/.env first "
            "(e.g. https://abc123.ngrok.io/payments/webhook)"
        )

    bunq_service.register_webhook(settings.bunq_webhook_url)
    print(f"Registered: {settings.bunq_webhook_url}")


if __name__ == "__main__":
    main()
