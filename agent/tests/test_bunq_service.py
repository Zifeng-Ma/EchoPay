"""
Layer 1: unit tests for bunq_service. BunqClient is mocked, so these run
without an API key and never touch the network. They verify our payload
construction, amount formatting, and response parsing.
"""

from unittest.mock import MagicMock, patch

import pytest

from app.services import bunq_service


# ---------------------------------------------------------------------------
# _fmt — amount cents → "X.XX"
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "cents,expected",
    [
        (0, "0.00"),
        (1, "0.01"),
        (10, "0.10"),
        (99, "0.99"),
        (100, "1.00"),
        (1050, "10.50"),
        (49900, "499.00"),
        (123456, "1234.56"),
    ],
)
def test_fmt_amount(cents, expected):
    assert bunq_service._fmt(cents) == expected


def test_fmt_rejects_negative():
    with pytest.raises(ValueError):
        bunq_service._fmt(-1)


# ---------------------------------------------------------------------------
# request_payment
# ---------------------------------------------------------------------------


@patch("app.services.bunq_service._get_client")
def test_request_payment_builds_correct_payload(mock_get):
    fake = MagicMock()
    fake.user_id = 42
    fake.post.return_value = [{"Id": {"id": 999}}]
    mock_get.return_value = (fake, 7)

    result = bunq_service.request_payment(
        amount_cents=1050,
        currency="EUR",
        payer_email="alice@example.com",
        description="Order #1",
    )

    assert result == {"request_id": 999, "status": "PENDING"}
    endpoint, body = fake.post.call_args[0]
    assert endpoint == "user/42/monetary-account/7/request-inquiry"
    assert body["amount_inquired"] == {"value": "10.50", "currency": "EUR"}
    assert body["counterparty_alias"] == {
        "type": "EMAIL",
        "value": "alice@example.com",
        "name": "alice@example.com",
    }
    assert body["description"] == "Order #1"
    assert body["allow_bunqme"] is False


# ---------------------------------------------------------------------------
# make_payment
# ---------------------------------------------------------------------------


@patch("app.services.bunq_service._get_client")
def test_make_payment_builds_correct_payload(mock_get):
    fake = MagicMock()
    fake.user_id = 42
    fake.post.return_value = [{"Id": {"id": 555}}]
    mock_get.return_value = (fake, 7)

    result = bunq_service.make_payment(
        amount_cents=2500,
        currency="EUR",
        recipient_email="bob@example.com",
        description="Tip",
    )

    assert result == {"payment_id": 555}
    endpoint, body = fake.post.call_args[0]
    assert endpoint == "user/42/monetary-account/7/payment"
    assert body["amount"] == {"value": "25.00", "currency": "EUR"}
    assert body["counterparty_alias"]["value"] == "bob@example.com"


# ---------------------------------------------------------------------------
# get_request_status
# ---------------------------------------------------------------------------


@patch("app.services.bunq_service._get_client")
def test_get_request_status_parses_response(mock_get):
    fake = MagicMock()
    fake.user_id = 42
    fake.get.return_value = [
        {
            "RequestInquiry": {
                "status": "ACCEPTED",
                "amount_inquired": {"value": "10.50", "currency": "EUR"},
            }
        }
    ]
    mock_get.return_value = (fake, 7)

    result = bunq_service.get_request_status(999)

    assert result == {"status": "ACCEPTED", "amount": "10.50", "currency": "EUR"}
    fake.get.assert_called_once_with("user/42/monetary-account/7/request-inquiry/999")


# ---------------------------------------------------------------------------
# register_webhook
# ---------------------------------------------------------------------------


@patch("app.services.bunq_service._get_client")
def test_register_webhook_posts_filters(mock_get):
    fake = MagicMock()
    fake.user_id = 42
    fake.post.return_value = [{}]
    mock_get.return_value = (fake, 7)

    bunq_service.register_webhook("https://example.com/hook")

    endpoint, body = fake.post.call_args[0]
    assert endpoint == "user/42/notification-filter-url"
    categories = {f["category"] for f in body["notification_filters"]}
    assert categories == {"PAYMENT", "MUTATION"}
    for f in body["notification_filters"]:
        assert f["notification_target"] == "https://example.com/hook"
