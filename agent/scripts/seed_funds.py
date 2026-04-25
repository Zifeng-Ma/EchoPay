"""
One-shot: ask sugardaddy@bunq.com to send €499 to the sandbox account.

Run once after creating a fresh sandbox API key. sugardaddy auto-accepts
requests up to €500, so we stay safely under the cap.

    cd agent
    python -m scripts.seed_funds
"""

from app.services import bunq_service


def main() -> None:
    resp = bunq_service.request_payment(
        amount_cents=49900,
        currency="EUR",
        payer_email="sugardaddy@bunq.com",
        description="EchoPay sandbox seed funds",
    )
    print(f"Seed request created: {resp}")
    print("sugardaddy auto-accepts within seconds — check the sandbox account balance.")


if __name__ == "__main__":
    main()
