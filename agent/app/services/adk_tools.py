"""ADK function tools for EchoPay's restaurant agent."""

from __future__ import annotations

import base64
import json
from typing import Any

from fastapi import HTTPException

from app.config import settings
from app.routes.voice import _transcribe_audio, _try_synthesize_speech
from app.services import bunq_service, customer_provisioning, supabase_context
from app.services.supabase_context import RequestUser


async def fetch_supabase_agent_context(
    user_id: str,
    restaurant_id: str = "",
    qr_location_id: str = "",
) -> dict[str, Any]:
    """Fetch the trusted Supabase context for a customer, restaurant, and QR location."""
    try:
        context = await supabase_context.load_agent_context(
            user=RequestUser(user_id=user_id, token=""),
            restaurant_id=restaurant_id or None,
            qr_location_id=qr_location_id or None,
            fallback_menu=[],
        )
    except HTTPException as exc:
        return {"status": "error", "message": str(exc.detail)}

    return {
        "status": "success",
        "customer": context.customer,
        "restaurant": context.restaurant,
        "qr_location": context.qr_location,
        "menu_items": context.menu_items,
        "recent_orders": context.recent_orders,
        "bunq_connected": context.bunq_connection is not None,
    }


async def search_supabase_menu_items(
    restaurant_id: str,
    query: str = "",
    category: str = "",
    limit: int = 12,
) -> dict[str, Any]:
    """Search menu items in Supabase by restaurant, optional text query, and optional category."""
    if not settings.supabase_url or not settings.supabase_service_role_key:
        return {"status": "unavailable", "items": []}

    params = {
        "restaurant_id": f"eq.{restaurant_id}",
        "select": (
            "id,restaurant_id,name,description,name_translations,"
            "description_translations,category,price,inventory_count,"
            "dietary_tags,is_available"
        ),
        "order": "category.asc,name.asc",
        "limit": str(max(1, min(limit, 50))),
    }
    if category.strip():
        params["category"] = f"eq.{category.strip()}"

    try:
        rows = await supabase_context._list("menu_items", params)
    except HTTPException as exc:
        return {"status": "error", "message": str(exc.detail), "items": []}

    needle = query.strip().lower()
    if needle:
        rows = [
            item
            for item in rows
            if needle in str(item.get("name") or "").lower()
            or needle in str(item.get("description") or "").lower()
            or needle in str(item.get("category") or "").lower()
        ]
    return {"status": "success", "items": rows[: max(1, min(limit, 50))]}


async def create_supabase_order_from_cart(
    user_id: str,
    restaurant_id: str,
    cart_items_json: str,
    qr_location_id: str = "",
) -> dict[str, Any]:
    """Create a Supabase order and order_items from a JSON encoded cart item list."""
    try:
        cart_items = json.loads(cart_items_json)
    except json.JSONDecodeError:
        return {"status": "error", "message": "cart_items_json must be valid JSON."}
    if not isinstance(cart_items, list):
        return {"status": "error", "message": "cart_items_json must decode to a list."}

    try:
        order_id = await supabase_context.create_order_from_cart(
            user_id=user_id,
            restaurant_id=restaurant_id,
            qr_location_id=qr_location_id or None,
            cart_items=[item for item in cart_items if isinstance(item, dict)],
        )
    except HTTPException as exc:
        return {"status": "error", "message": str(exc.detail)}
    return {"status": "success", "order_id": order_id}


async def update_supabase_order(
    order_id: str,
    updates_json: str,
) -> dict[str, Any]:
    """Patch a Supabase order with a JSON object of allowed order updates."""
    try:
        updates = json.loads(updates_json)
    except json.JSONDecodeError:
        return {"status": "error", "message": "updates_json must be valid JSON."}
    if not isinstance(updates, dict):
        return {"status": "error", "message": "updates_json must decode to an object."}

    try:
        await supabase_context.update_order(order_id, updates)
    except HTTPException as exc:
        return {"status": "error", "message": str(exc.detail)}
    return {"status": "success", "order_id": order_id}


async def transcribe_audio_from_base64(
    audio_base64: str,
    filename: str = "agent-audio.wav",
    content_type: str = "audio/wav",
    language: str = "en",
) -> dict[str, Any]:
    """Transcribe base64 encoded audio with the EchoPay STT wrapper."""
    try:
        audio_bytes = base64.b64decode(audio_base64.encode("ascii"))
    except (ValueError, UnicodeEncodeError):
        return {"status": "error", "message": "audio_base64 must be valid base64."}

    try:
        result = await _transcribe_audio(
            filename=filename,
            content_type=content_type,
            audio_bytes=audio_bytes,
            language=language,
        )
    except HTTPException as exc:
        return {"status": "error", "message": str(exc.detail)}

    return {
        "status": "success",
        "transcript": result.transcript,
        "speaker_turns": [turn.to_json() for turn in result.speaker_turns],
    }


async def synthesize_speech_to_base64(text: str) -> dict[str, str]:
    """Synthesize assistant speech with the EchoPay TTS wrapper."""
    if settings.openai_api_key == "test-key":
        return {"status": "disabled"}
    speech = await _try_synthesize_speech(text)
    return {"status": "success" if speech else "unavailable", **speech}


async def execute_bunq_payment(
    user_id: str,
    order_id: str,
    amount_cents: int,
    currency: str = "EUR",
    description: str = "",
) -> dict[str, Any]:
    """Execute a bunq payment for a confirmed order.

    Resolves the user's bunq token, the restaurant's payment alias, and sends
    a direct payment via the bunq sandbox API. Updates the order status to
    'confirmed' on success.

    Args:
        user_id: The Supabase user ID of the paying customer.
        order_id: The Supabase order ID to pay for.
        amount_cents: Total amount in cents (e.g. 450 = EUR 4.50).
        currency: ISO currency code, defaults to EUR.
        description: Payment description shown in bunq.
    """
    # 1. Fetch the order to get the restaurant_id
    try:
        order = await supabase_context._maybe_single(
            "orders", {"id": f"eq.{order_id}"}
        )
    except Exception as exc:
        return {"status": "error", "message": f"Failed to fetch order: {exc}"}
    if not order:
        return {"status": "error", "message": "Order not found."}
    if order.get("order_status") in ("confirmed", "cancelled"):
        return {"status": "error", "message": f"Order already {order['order_status']}."}

    # 2. Resolve merchant alias from restaurant
    try:
        restaurant = await supabase_context._maybe_single(
            "restaurants", {"id": f"eq.{order['restaurant_id']}"}
        )
    except Exception as exc:
        return {"status": "error", "message": f"Failed to fetch restaurant: {exc}"}

    merchant_alias = str(
        (restaurant or {}).get("bunq_recipient_alias")
        or settings.bunq_merchant_alias
        or ""
    ).strip()
    merchant_alias_type = str(
        (restaurant or {}).get("bunq_recipient_alias_type")
        or settings.bunq_merchant_alias_type
        or "EMAIL"
    ).strip()
    if not merchant_alias:
        return {"status": "error", "message": "Restaurant has no bunq payment alias configured."}

    # 3. Resolve customer's bunq token (auto-provision if needed)
    token = await supabase_context.get_bunq_payment_token(user_id)
    if not token:
        try:
            await customer_provisioning.provision_for(user_id)
            token = await supabase_context.get_bunq_payment_token(user_id)
        except Exception as exc:
            return {"status": "error", "message": f"Failed to provision bunq account: {exc}"}
    if not token:
        return {"status": "error", "message": "Could not obtain bunq payment token."}

    # 4. Execute the bunq payment
    if not description:
        description = f"EchoPay order {order_id}"
    try:
        payment = bunq_service.make_user_payment_from_oauth(
            oauth_access_token=token,
            amount_cents=amount_cents,
            currency=currency,
            recipient_alias=merchant_alias,
            recipient_alias_type=merchant_alias_type,
            description=description,
        )
    except Exception as exc:
        return {"status": "error", "message": f"bunq payment failed: {exc}"}

    # 5. Mark order as confirmed
    payment_id = str(payment.get("payment_id") or "")
    try:
        await supabase_context.update_order(
            order_id,
            {"order_status": "confirmed", "bunq_transaction_id": payment_id},
        )
    except Exception as exc:
        return {"status": "error", "message": f"Payment sent but order update failed: {exc}"}

    return {
        "status": "success",
        "order_id": order_id,
        "payment_id": payment_id,
        "message": "Payment confirmed and order updated.",
    }


ADK_TOOLS = [
    fetch_supabase_agent_context,
    search_supabase_menu_items,
    create_supabase_order_from_cart,
    update_supabase_order,
    execute_bunq_payment,
    transcribe_audio_from_base64,
    synthesize_speech_to_base64,
]
