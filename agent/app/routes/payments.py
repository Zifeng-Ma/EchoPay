"""
Thin HTTP layer over `bunq_service`. Pydantic models on the boundary; no
business logic here. Webhook route currently logs and ACKs — the Supabase
teammate plugs in order-status updates at the marked TODO.
"""

import logging
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from app.config import settings
from app.services import bunq_service, customer_provisioning, supabase_context
from app.services.supabase_context import RequestUser

router = APIRouter(prefix="/payments", tags=["payments"])
compat_router = APIRouter(tags=["payments"])
log = logging.getLogger(__name__)


class RequestPaymentBody(BaseModel):
    amount_cents: int = Field(gt=0)
    currency: str = "EUR"
    payer_email: str
    description: str


class DirectPaymentBody(BaseModel):
    amount_cents: int = Field(gt=0)
    currency: str = "EUR"
    recipient_email: str
    description: str


class InitiatePaymentBody(BaseModel):
    order_id: str
    amount_cents: int = Field(gt=0)
    currency: str = "EUR"
    description: str = "EchoPay Order"
    payer_email: str | None = None


class PayOrderBody(BaseModel):
    order_id: str


@router.post("/request")
def create_request(body: RequestPaymentBody) -> dict:
    try:
        return bunq_service.request_payment(**body.model_dump())
    except Exception as e:
        log.exception("bunq request_payment failed")
        raise HTTPException(status_code=502, detail=f"bunq error: {e}")


@compat_router.post("/payment/initiate")
def initiate_payment_compat(body: InitiatePaymentBody) -> dict:
    """
    Compatibility shape for the current Flutter PaymentService.

    The mobile app does not yet collect a payer alias, so this route can only
    create a real bunq request when `payer_email` is supplied by a newer client.
    Otherwise it returns a stable transaction reference for the existing order
    polling flow.
    """
    if body.payer_email:
        try:
            result = bunq_service.request_payment(
                amount_cents=body.amount_cents,
                currency=body.currency,
                payer_email=body.payer_email,
                description=body.description,
            )
        except Exception as e:
            log.exception("bunq compatibility request failed")
            raise HTTPException(status_code=502, detail=f"bunq error: {e}")
        transaction_ref = str(result["request_id"])
        return {"transaction_ref": transaction_ref, **result}

    return {
        "transaction_ref": f"manual-{body.order_id}-{uuid4().hex[:8]}",
        "status": "pending_external_confirmation",
    }


@router.post("/direct")
def create_direct_payment(body: DirectPaymentBody) -> dict:
    try:
        return bunq_service.make_payment(**body.model_dump())
    except Exception as e:
        log.exception("bunq make_payment failed")
        raise HTTPException(status_code=502, detail=f"bunq error: {e}")


@router.get("/request/{request_id}")
def get_request(request_id: int) -> dict:
    try:
        return bunq_service.get_request_status(request_id)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"bunq error: {e}")


@compat_router.post("/payment/pay")
async def pay_order(
    body: PayOrderBody,
    user: RequestUser = Depends(supabase_context.require_user),
) -> dict:
    """
    Execute a bunq OAuth payment on behalf of the authenticated user.

    Fetches the order total and restaurant bunq alias from Supabase, uses the
    user's stored OAuth token to send a direct payment, then marks the order
    as confirmed. Called by the Flutter "Pay Now" button on the Orders screen.
    """
    try:
        order = await supabase_context._maybe_single("orders", {"id": f"eq.{body.order_id}"})
    except Exception as e:
        log.exception("pay_order: failed to fetch order %s", body.order_id)
        raise HTTPException(status_code=502, detail=f"Failed to fetch order: {e}")
    if not order:
        raise HTTPException(status_code=404, detail="Order not found.")
    if order.get("order_status") in ("confirmed", "cancelled"):
        raise HTTPException(status_code=400, detail=f"Order already {order['order_status']}.")

    try:
        restaurant = await supabase_context._maybe_single(
            "restaurants", {"id": f"eq.{order['restaurant_id']}"}
        )
    except Exception as e:
        log.exception("pay_order: failed to fetch restaurant for order %s", body.order_id)
        raise HTTPException(status_code=502, detail=f"Failed to fetch restaurant: {e}")
    if not restaurant:
        raise HTTPException(status_code=404, detail="Restaurant not found.")

    merchant_alias = str(
        restaurant.get("bunq_recipient_alias") or settings.bunq_merchant_alias or ""
    ).strip()
    merchant_alias_type = str(
        restaurant.get("bunq_recipient_alias_type") or settings.bunq_merchant_alias_type or "EMAIL"
    ).strip()
    if not merchant_alias:
        raise HTTPException(
            status_code=400,
            detail="Restaurant has no bunq payment alias configured.",
        )

    token = await supabase_context.get_bunq_payment_token(user.user_id)
    if not token:
        # Auto-provision a bunq sandbox account on first payment attempt
        try:
            log.info("pay_order: auto-provisioning bunq account for user %s", user.user_id)
            await customer_provisioning.provision_for(user.user_id)
            token = await supabase_context.get_bunq_payment_token(user.user_id)
        except Exception as e:
            log.exception("pay_order: auto-provision failed for user %s", user.user_id)
            raise HTTPException(
                status_code=502, detail=f"Failed to provision bunq account: {e}"
            )
    if not token:
        raise HTTPException(
            status_code=400,
            detail="Could not obtain a bunq payment token after provisioning.",
        )
    try:
        payment = bunq_service.make_user_payment_from_oauth(
            oauth_access_token=token,
            amount_cents=int(order["total_amount"]),
            currency=str(restaurant.get("currency") or "EUR"),
            recipient_alias=merchant_alias,
            recipient_alias_type=merchant_alias_type,
            description=f"EchoPay order {body.order_id}",
        )
    except Exception as e:
        log.exception("bunq pay_order failed for order %s", body.order_id)
        raise HTTPException(status_code=502, detail=f"bunq payment failed: {e}")

    payment_id = str(payment.get("payment_id") or "")
    await supabase_context.update_order(
        body.order_id,
        {"order_status": "confirmed", "bunq_transaction_id": payment_id},
    )
    log.info("pay_order: order %s confirmed, bunq payment_id=%s", body.order_id, payment_id)
    return {"payment_id": payment_id, "order_id": body.order_id, "status": "confirmed"}


@router.post("/webhook")
async def bunq_webhook(req: Request) -> dict:
    """
    bunq webhook endpoint (for backward compat).

    In production, use a Supabase Edge Function instead:
      supabase/functions/bunq-webhook/index.ts

    Register the Edge Function URL as the bunq webhook notification URL.
    """
    payload = await req.json()
    log.info("bunq webhook received: %s", payload)
    return {"ok": True}
