"""
Layer 2: HTTP route tests via FastAPI TestClient.

The bunq_service module is patched, so these tests verify our HTTP layer:
status codes, Pydantic validation, error mapping, webhook acceptance.
"""

from unittest.mock import patch


# ---------------------------------------------------------------------------
# /payments/request
# ---------------------------------------------------------------------------


def test_create_request_happy_path(client):
    with patch(
        "app.services.bunq_service.request_payment",
        return_value={"request_id": 111, "status": "PENDING"},
    ) as mock:
        r = client.post(
            "/payments/request",
            json={
                "amount_cents": 1050,
                "currency": "EUR",
                "payer_email": "alice@example.com",
                "description": "Order #1",
            },
        )
    assert r.status_code == 200
    assert r.json() == {"request_id": 111, "status": "PENDING"}
    mock.assert_called_once_with(
        amount_cents=1050,
        currency="EUR",
        payer_email="alice@example.com",
        description="Order #1",
    )


def test_create_request_rejects_zero_amount(client):
    r = client.post(
        "/payments/request",
        json={
            "amount_cents": 0,
            "currency": "EUR",
            "payer_email": "alice@example.com",
            "description": "x",
        },
    )
    assert r.status_code == 422


def test_create_request_returns_502_on_bunq_error(client):
    with patch(
        "app.services.bunq_service.request_payment",
        side_effect=RuntimeError("bunq is down"),
    ):
        r = client.post(
            "/payments/request",
            json={
                "amount_cents": 100,
                "currency": "EUR",
                "payer_email": "a@b.com",
                "description": "x",
            },
        )
    assert r.status_code == 502
    assert "bunq is down" in r.json()["detail"]


# ---------------------------------------------------------------------------
# /payments/direct
# ---------------------------------------------------------------------------


def test_create_direct_payment_happy_path(client):
    with patch(
        "app.services.bunq_service.make_payment",
        return_value={"payment_id": 222},
    ) as mock:
        r = client.post(
            "/payments/direct",
            json={
                "amount_cents": 2500,
                "currency": "EUR",
                "recipient_email": "bob@example.com",
                "description": "Tip",
            },
        )
    assert r.status_code == 200
    assert r.json() == {"payment_id": 222}
    mock.assert_called_once()


def test_create_direct_payment_rejects_negative_amount(client):
    r = client.post(
        "/payments/direct",
        json={
            "amount_cents": -1,
            "currency": "EUR",
            "recipient_email": "b@c.com",
            "description": "x",
        },
    )
    assert r.status_code == 422


# ---------------------------------------------------------------------------
# /payments/request/{id}
# ---------------------------------------------------------------------------


def test_get_request_status_happy_path(client):
    with patch(
        "app.services.bunq_service.get_request_status",
        return_value={"status": "ACCEPTED", "amount": "10.50", "currency": "EUR"},
    ) as mock:
        r = client.get("/payments/request/789")
    assert r.status_code == 200
    assert r.json()["status"] == "ACCEPTED"
    mock.assert_called_once_with(789)


# ---------------------------------------------------------------------------
# /payments/webhook — sample bunq-shaped payload
# ---------------------------------------------------------------------------


def test_webhook_accepts_request_inquiry_event(client):
    payload = {
        "NotificationUrl": {
            "target_url": "https://x/payments/webhook",
            "category": "REQUEST",
            "event_type": "REQUEST_INQUIRY_ACCEPTED",
            "object": {
                "RequestInquiry": {
                    "id": 789,
                    "status": "ACCEPTED",
                    "amount_inquired": {"value": "10.50", "currency": "EUR"},
                }
            },
        }
    }
    r = client.post("/payments/webhook", json=payload)
    assert r.status_code == 200
    assert r.json() == {"ok": True}


def test_webhook_accepts_payment_event(client):
    payload = {
        "NotificationUrl": {
            "target_url": "https://x/payments/webhook",
            "category": "PAYMENT",
            "event_type": "PAYMENT_CREATED",
            "object": {
                "Payment": {
                    "id": 12345,
                    "amount": {"value": "10.50", "currency": "EUR"},
                }
            },
        }
    }
    r = client.post("/payments/webhook", json=payload)
    assert r.status_code == 200
