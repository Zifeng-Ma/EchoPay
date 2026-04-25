"""Agent routes for restaurant-aware text/audio turns."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlencode

import httpx
from fastapi import APIRouter, Depends, File, Form, Header, HTTPException, UploadFile
from pydantic import BaseModel, Field

from app.config import settings
from app.routes.voice import _transcribe_audio, _try_synthesize_speech
from app.services import bunq_service
from app.services import supabase_context
from app.services.supabase_context import AgentContext, RequestUser

router = APIRouter(prefix="/agent", tags=["agent"])
bunq_router = APIRouter(prefix="/bunq", tags=["bunq"])


@dataclass(slots=True)
class PendingAction:
    action_type: str
    message: str
    cart_intents: list[dict[str, Any]]
    restaurant_id: str | None = None
    qr_location_id: str | None = None


@dataclass(slots=True)
class ConversationTurn:
    role: str
    text: str


_PENDING_ACTIONS: dict[tuple[str, str], PendingAction] = {}
_SESSION_MEMORY: dict[tuple[str, str], list[ConversationTurn]] = {}
_MAX_MEMORY_TURNS = 16


class AgentTextRequest(BaseModel):
    text: str
    restaurant_id: str | None = None
    qr_location_id: str | None = None
    session_id: str | None = None
    language: str = "en"
    menu_context: list[dict[str, Any]] = Field(default_factory=list)
    cart_context: list[dict[str, Any]] = Field(default_factory=list)
    confirm_action: bool = False


@router.post("/turn")
async def agent_turn(
    request: AgentTextRequest,
    user: RequestUser = Depends(supabase_context.require_user),
) -> dict[str, Any]:
    context = await supabase_context.load_agent_context(
        user=user,
        restaurant_id=request.restaurant_id,
        qr_location_id=request.qr_location_id,
        fallback_menu=request.menu_context,
    )
    return await _handle_turn(
        text=request.text,
        transcript="",
        session_id=request.session_id or "default",
        language=request.language,
        context=context,
        cart_context=request.cart_context,
        confirm_action=request.confirm_action,
    )


@router.post("/voice")
async def agent_voice(
    audio: UploadFile = File(...),
    restaurant_id: str = Form(default=""),
    qr_location_id: str = Form(default=""),
    session_id: str = Form(default="default"),
    language: str = Form(default="en"),
    menu_context: str = Form(default="[]"),
    cart_context: str = Form(default="[]"),
    confirm_action: bool = Form(default=False),
    authorization: str | None = Header(default=None),
) -> dict[str, Any]:
    user = await supabase_context.require_user(authorization)
    audio_bytes = await audio.read()
    if not audio_bytes:
        raise HTTPException(status_code=400, detail="Audio upload was empty.")

    transcription = await _transcribe_audio(
        filename=audio.filename or "agent-voice.m4a",
        content_type=audio.content_type or "audio/m4a",
        audio_bytes=audio_bytes,
        language=language,
    )

    fallback_menu = _decode_list(menu_context)
    context = await supabase_context.load_agent_context(
        user=user,
        restaurant_id=restaurant_id or None,
        qr_location_id=qr_location_id or None,
        fallback_menu=fallback_menu,
    )
    return await _handle_turn(
        text=transcription.transcript,
        transcript=transcription.transcript,
        session_id=session_id or "default",
        language=language,
        context=context,
        cart_context=_decode_list(cart_context),
        confirm_action=confirm_action,
    )


@router.post("/text")
async def agent_text(request: AgentTextRequest) -> dict[str, Any]:
    """Legacy compatibility endpoint used by older Flutter tests/client code."""
    return _build_legacy_agent_response(request.text, request.menu_context)


@bunq_router.get("/status")
async def bunq_status(user: RequestUser = Depends(supabase_context.require_user)) -> dict[str, Any]:
    connection = await supabase_context.get_bunq_connection(user.user_id)
    return {"connected": connection is not None}


@bunq_router.get("/oauth/start")
async def bunq_oauth_start(user: RequestUser = Depends(supabase_context.require_user)) -> dict[str, Any]:
    if not settings.bunq_oauth_client_id or not settings.bunq_oauth_redirect_uri:
        raise HTTPException(status_code=503, detail="bunq OAuth is not configured.")
    base_url = "https://oauth.sandbox.bunq.com/auth" if settings.bunq_use_sandbox else "https://oauth.bunq.com/auth"
    query = urlencode(
        {
            "response_type": "code",
            "client_id": settings.bunq_oauth_client_id,
            "redirect_uri": settings.bunq_oauth_redirect_uri,
            "state": user.user_id,
        }
    )
    return {"authorization_url": f"{base_url}?{query}"}


@bunq_router.get("/oauth/callback")
async def bunq_oauth_callback(code: str, state: str) -> dict[str, Any]:
    if (
        not settings.bunq_oauth_client_id
        or not settings.bunq_oauth_client_secret
        or not settings.bunq_oauth_redirect_uri
    ):
        raise HTTPException(status_code=503, detail="bunq OAuth is not configured.")

    token_url = (
        "https://api-oauth.sandbox.bunq.com/v1/token"
        if settings.bunq_use_sandbox
        else "https://api.oauth.bunq.com/v1/token"
    )
    async with httpx.AsyncClient(timeout=30.0) as client:
        response = await client.post(
            token_url,
            params={
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": settings.bunq_oauth_redirect_uri,
                "client_id": settings.bunq_oauth_client_id,
                "client_secret": settings.bunq_oauth_client_secret,
            },
        )
    if response.status_code >= 400:
        raise HTTPException(status_code=502, detail=f"bunq OAuth failed: {response.text}")
    payload = response.json()
    access_token = str(payload.get("access_token") or "").strip()
    if not access_token:
        raise HTTPException(status_code=502, detail="bunq OAuth returned no access token.")
    await supabase_context.upsert_bunq_connection(user_id=state, access_token=access_token)
    return {"connected": True}


async def _handle_turn(
    *,
    text: str,
    transcript: str,
    session_id: str,
    language: str,
    context: AgentContext,
    cart_context: list[dict[str, Any]],
    confirm_action: bool,
) -> dict[str, Any]:
    normalized = text.strip()
    key = ((context.user.user_id if context.user else "guest"), session_id)
    history = list(_SESSION_MEMORY.get(key, []))

    if confirm_action or _is_confirmation(normalized):
        pending = _PENDING_ACTIONS.pop(key, None)
        if pending is not None:
            response = await _execute_pending_action(
                pending=pending,
                text=normalized,
                transcript=transcript,
                context=context,
                cart_context=cart_context,
            )
            _remember_turn(key, normalized, str(response.get("message") or ""))
            if pending.action_type == "checkout" and response.get("payment_status") == "confirmed":
                _clear_session_state(key)
            return response

    cart_intents = _extract_cart_intents(normalized, context.menu_items)
    wants_checkout = _mentions_checkout(normalized)
    if cart_intents or wants_checkout:
        pending = PendingAction(
            action_type="checkout" if wants_checkout else "cart",
            message=_confirmation_message(cart_intents, wants_checkout, context),
            cart_intents=cart_intents,
            restaurant_id=str((context.restaurant or {}).get("id") or ""),
            qr_location_id=str((context.qr_location or {}).get("id") or ""),
        )
        _PENDING_ACTIONS[key] = pending
        response = await _response(
            message=pending.message,
            transcript=transcript,
            language=language,
            requires_confirmation=True,
            pending_action={
                "type": pending.action_type,
                "message": pending.message,
                "cart_intents": pending.cart_intents,
            },
        )
        _remember_turn(key, normalized, pending.message)
        return response

    message = await _generate_context_answer(
        normalized,
        context,
        language,
        conversation_history=history,
        cart_context=cart_context,
    )
    response = await _response(message=message, transcript=transcript, language=language)
    _remember_turn(key, normalized, message)
    return response


async def _execute_pending_action(
    *,
    pending: PendingAction,
    text: str,
    transcript: str,
    context: AgentContext,
    cart_context: list[dict[str, Any]],
) -> dict[str, Any]:
    if pending.action_type == "cart":
        return await _response(
            message="Done. I've updated your order.",
            transcript=transcript,
            language="en",
            cart_intents=pending.cart_intents,
            action_result={"status": "completed", "type": "cart"},
        )

    if not context.bunq_connection:
        return await _response(
            message="Your order is ready, but I need you to connect bunq before I can start payment.",
            transcript=transcript,
            language="en",
            cart_intents=pending.cart_intents,
            requires_confirmation=False,
            action_result={"status": "needs_bunq_connection", "type": "payment"},
        )

    restaurant = context.restaurant or {}
    merchant_alias = str(
        restaurant.get("bunq_recipient_alias")
        or restaurant.get("bunq_merchant_alias")
        or restaurant.get("payment_alias")
        or settings.bunq_merchant_alias
        or ""
    ).strip()
    merchant_alias_type = str(
        restaurant.get("bunq_recipient_alias_type")
        or restaurant.get("bunq_merchant_alias_type")
        or settings.bunq_merchant_alias_type
        or "EMAIL"
    ).strip()
    if not merchant_alias:
        return await _response(
            message="The order is ready, but this restaurant still needs a bunq payment destination configured.",
            transcript=transcript,
            language="en",
            cart_intents=pending.cart_intents,
            action_result={"status": "needs_payment_destination", "type": "payment"},
        )

    order_id = await supabase_context.create_order_from_cart(
        user_id=context.user.user_id if context.user else "",
        restaurant_id=pending.restaurant_id or str((context.restaurant or {}).get("id") or ""),
        qr_location_id=pending.qr_location_id or None,
        cart_items=cart_context,
    )
    total_cents = sum(_as_int(item.get("line_total"), _as_int(item.get("base_price"), 0) * _as_int(item.get("quantity"), 1)) for item in cart_context)
    oauth_token = supabase_context.decode_stored_secret(
        str(context.bunq_connection.get("access_token_encrypted") or "")
    )
    payment = bunq_service.make_user_payment_from_oauth(
        oauth_access_token=oauth_token,
        amount_cents=total_cents,
        currency=str((context.restaurant or {}).get("currency") or "EUR"),
        recipient_alias=merchant_alias,
        recipient_alias_type=merchant_alias_type,
        description=f"EchoPay order {order_id}",
    )
    payment_id = str(payment.get("payment_id") or "")
    await supabase_context.update_order(
        order_id,
        {
            "order_status": "confirmed",
            "bunq_transaction_id": payment_id,
        },
    )
    return await _response(
        message="Payment is confirmed. I've sent the order to the restaurant.",
        transcript=transcript,
        language="en",
        cart_intents=pending.cart_intents,
        action_result={
            "status": "confirmed",
            "type": "payment",
            "order_id": order_id,
            "bunq_transaction_id": payment_id,
        },
        order_id=order_id,
        payment_status="confirmed",
    )


async def _response(
    *,
    message: str,
    transcript: str,
    language: str,
    cart_intents: list[dict[str, Any]] | None = None,
    requires_confirmation: bool = False,
    pending_action: dict[str, Any] | None = None,
    action_result: dict[str, Any] | None = None,
    order_id: str | None = None,
    payment_status: str | None = None,
) -> dict[str, Any]:
    speech = await _try_synthesize_speech(message)
    intents = cart_intents or []
    trigger_checkout = any(intent.get("action") == "checkout" for intent in intents)
    return {
        "message": message,
        "agent_response": message,
        "transcript": transcript,
        "intents": intents,
        "cart_intents": intents,
        "trigger_checkout": trigger_checkout,
        "requires_confirmation": requires_confirmation,
        "pending_action": pending_action,
        "action_result": action_result,
        "order_id": order_id,
        "payment_status": payment_status,
        "agent_audio_base64": speech.get("agent_audio_base64", ""),
        "agent_audio_content_type": speech.get("agent_audio_content_type", "audio/wav"),
    }


async def _generate_context_answer(
    text: str,
    context: AgentContext,
    language: str,
    *,
    conversation_history: list[ConversationTurn],
    cart_context: list[dict[str, Any]],
) -> str:
    if not text:
        return "What would you like to know or order?"

    restaurant = context.restaurant or {}
    customer = context.customer or {}
    history_text = _format_conversation_history(conversation_history)
    prompt = (
        "You are the EchoPay restaurant assistant. Answer naturally and briefly. "
        "You may answer broad questions, but prioritize the restaurant, customer, menu, allergies, "
        "dietary preferences, opening hours, order status, and payment context.\n\n"
        "Use the recent conversation history as memory for this order process. "
        "If the user refers to something they just said, resolve it from that history or the current cart.\n\n"
        f"Customer profile: {json.dumps(customer, default=str)[:1200]}\n"
        f"Restaurant: {json.dumps(restaurant, default=str)[:1200]}\n"
        f"Menu: {json.dumps(context.menu_items, default=str)[:4000]}\n"
        f"Current cart: {json.dumps(cart_context, default=str)[:1800]}\n"
        f"Recent orders: {json.dumps(context.recent_orders, default=str)[:1800]}\n"
        f"Recent conversation:\n{history_text}\n"
        f"Language: {language}\n"
        f"User message: {text}"
    )
    try:
        async with httpx.AsyncClient(timeout=45.0) as client:
            response = await client.post(
                "https://api.openai.com/v1/responses",
                headers={
                    "Authorization": f"Bearer {settings.openai_api_key}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": settings.openai_order_model,
                    "input": [
                        {
                            "role": "user",
                            "content": [{"type": "input_text", "text": prompt}],
                        }
                    ],
                },
            )
        if response.status_code < 400:
            output = _extract_output_text(response.json()).strip()
            if output:
                return output
    except (httpx.HTTPError, ValueError):
        pass

    name = str(restaurant.get("name") or "this restaurant")
    return f"I can help with {name}'s menu, ordering, payment, and general questions."


def _remember_turn(key: tuple[str, str], user_text: str, assistant_text: str) -> None:
    turns = _SESSION_MEMORY.setdefault(key, [])
    if user_text.strip():
        turns.append(ConversationTurn(role="user", text=user_text.strip()))
    if assistant_text.strip():
        turns.append(ConversationTurn(role="assistant", text=assistant_text.strip()))
    del turns[:-_MAX_MEMORY_TURNS]


def _clear_session_state(key: tuple[str, str]) -> None:
    _PENDING_ACTIONS.pop(key, None)
    _SESSION_MEMORY.pop(key, None)


def _format_conversation_history(history: list[ConversationTurn]) -> str:
    if not history:
        return "No previous turns in this order session."
    lines = []
    for turn in history[-_MAX_MEMORY_TURNS:]:
        text = re.sub(r"\s+", " ", turn.text).strip()
        if text:
            lines.append(f"{turn.role}: {text}")
    return "\n".join(lines) or "No previous turns in this order session."


def _extract_output_text(response_json: dict[str, Any]) -> str:
    chunks: list[str] = []
    for item in response_json.get("output", []):
        if not isinstance(item, dict):
            continue
        for content in item.get("content", []):
            if isinstance(content, dict) and content.get("type") in {"output_text", "text"}:
                chunks.append(str(content.get("text") or ""))
    return "\n".join(chunks)


def _extract_cart_intents(text: str, menu_context: list[dict[str, Any]]) -> list[dict[str, Any]]:
    normalized = text.lower()
    intents: list[dict[str, Any]] = []
    if _mentions_clear_cart(normalized):
        intents.append({"action": "clear_cart", "quantity": 1, "modifiers": []})
    for item in menu_context:
        name = str(item.get("name") or "").strip()
        item_id = str(item.get("id") or "").strip()
        if not name or not _mentions_item(normalized, name):
            continue
        intents.append(
            {
                "action": "add_item",
                "menu_item_id": item_id or None,
                "name": name,
                "quantity": _extract_quantity(normalized, name),
                "modifiers": [],
                "special_instructions": None,
            }
        )
    if _mentions_checkout(normalized):
        intents.append({"action": "checkout", "quantity": 1, "modifiers": []})
    return intents


def _confirmation_message(
    cart_intents: list[dict[str, Any]],
    wants_checkout: bool,
    context: AgentContext,
) -> str:
    item_names = [
        f"{intent.get('quantity', 1)} x {intent.get('name')}"
        for intent in cart_intents
        if intent.get("action") == "add_item" and intent.get("name")
    ]
    if wants_checkout:
        return "I can get checkout ready. Please confirm if you want me to create the order and start payment."
    if item_names:
        return f"I can add {', '.join(item_names)} to your order. Please confirm."
    return "I can update your order. Please confirm."


def _is_confirmation(text: str) -> bool:
    normalized = text.lower().strip()
    return normalized in {"yes", "yeah", "yep", "correct", "confirm", "confirmed", "do it", "go ahead"}


def _decode_list(raw: str) -> list[dict[str, Any]]:
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return []
    if not isinstance(parsed, list):
        return []
    return [item for item in parsed if isinstance(item, dict)]


def _build_legacy_agent_response(text: str, menu_context: list[dict[str, Any]]) -> dict[str, Any]:
    intents = _extract_cart_intents(text, menu_context)
    trigger_checkout = any(intent.get("action") == "checkout" for intent in intents)
    if intents:
        message = "I've updated your order."
    elif trigger_checkout:
        message = "I'll get checkout ready."
    else:
        message = "What would you like to order?"
    return {"message": message, "intents": intents, "trigger_checkout": trigger_checkout}


def _mentions_item(text: str, name: str) -> bool:
    normalized_name = re.sub(r"\s+", " ", name.lower()).strip()
    return normalized_name in text


def _mentions_clear_cart(text: str) -> bool:
    return any(
        phrase in text
        for phrase in (
            "clear cart",
            "clear my order",
            "cancel my order",
            "start over",
        )
    )


def _mentions_checkout(text: str) -> bool:
    return any(
        phrase in text
        for phrase in (
            "checkout",
            "check out",
            "pay",
            "ready to order",
            "that's all",
            "that is all",
        )
    )


def _extract_quantity(text: str, item_name: str) -> int:
    words = {
        "a": 1,
        "an": 1,
        "one": 1,
        "two": 2,
        "three": 3,
        "four": 4,
        "five": 5,
        "six": 6,
        "seven": 7,
        "eight": 8,
        "nine": 9,
        "ten": 10,
    }
    escaped = re.escape(item_name.lower())
    match = re.search(rf"\b(\d+|{'|'.join(words)})\s+{escaped}(?:s|es)?\b", text)
    if match is None:
        return 1
    raw = match.group(1)
    if raw.isdigit():
        return max(int(raw), 1)
    return words.get(raw, 1)


def _as_int(value: Any, fallback: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return fallback
