"""ADK-backed agent loop used by the Flutter-facing FastAPI routes."""

from __future__ import annotations

import asyncio
import json
import os
import re
from dataclasses import dataclass
from typing import Any

from fastapi import HTTPException
from google.adk.agents import LlmAgent
from google.adk.models.lite_llm import LiteLlm
from google.adk.runners import Runner
from google.adk.sessions import InMemorySessionService
from google.genai import types

from app.config import settings
from app.routes.voice import _try_synthesize_speech
from app.services import bunq_service, customer_provisioning, supabase_context
from app.services.adk_tools import ADK_TOOLS
from app.services.supabase_context import AgentContext

APP_NAME = "echopay_adk"
_MAX_MEMORY_TURNS = 16


@dataclass(slots=True)
class PendingAction:
    action_type: str
    message: str
    cart_intents: list[dict[str, Any]]
    restaurant_id: str = ""
    qr_location_id: str = ""


@dataclass(slots=True)
class ConversationTurn:
    role: str
    text: str


@dataclass(slots=True)
class SessionMemoryState:
    allergies: list[str]
    dietary_preferences: list[str]
    likes: list[str]
    dislikes: list[str]
    unresolved_questions: list[str]
    last_user_goal: str
    last_referenced_items: list[str]
    customer_name: str
    summary: str

    def to_json(self) -> dict[str, Any]:
        return {
            "allergies": self.allergies,
            "dietary_preferences": self.dietary_preferences,
            "likes": self.likes,
            "dislikes": self.dislikes,
            "unresolved_questions": self.unresolved_questions,
            "last_user_goal": self.last_user_goal,
            "last_referenced_items": self.last_referenced_items,
            "customer_name": self.customer_name,
            "summary": self.summary,
        }


_PENDING_ACTIONS: dict[tuple[str, str], PendingAction] = {}
_SESSION_MEMORY: dict[tuple[str, str], list[ConversationTurn]] = {}
_SESSION_FACTS: dict[tuple[str, str], SessionMemoryState] = {}
_MENU_INTRO_PROGRESS: dict[tuple[str, str], int] = {}
_SESSION_SERVICE = InMemorySessionService()
_RUNNER: Runner | None = None

# Per-session lock prevents concurrent turns from corrupting ADK session state.
# When a phone disconnects mid-request, the in-flight turn holds the lock until
# it finishes or times out, then the next request can proceed cleanly.
_SESSION_LOCKS: dict[tuple[str, str], asyncio.Lock] = {}
_TURN_TIMEOUT_SECONDS = 45


def _session_lock(key: tuple[str, str]) -> asyncio.Lock:
    if key not in _SESSION_LOCKS:
        _SESSION_LOCKS[key] = asyncio.Lock()
    return _SESSION_LOCKS[key]


AGENT_INSTRUCTION = """
You are EchoPay, a voice-first restaurant ordering and payment agent.

You receive one customer turn at a time from the Flutter app. The app gives you
trusted restaurant context, menu context, current cart, prior session memory, and
whether the user is confirming a pending action.

Use the Supabase tools when the supplied context is missing or stale. Use the
execute_bunq_payment tool to process payments when the user confirms checkout
and the order has been created — pass the user_id, order_id, amount_cents, and
currency. The STT and TTS tools are available for agent workflows that provide
base64 audio or need speech output, but the Flutter adapter normally performs
STT before your turn and TTS after your JSON response.

Hard rules:
- Return JSON only. No Markdown and no prose outside the JSON object.
- Keep `message` concise and suitable for both display and speech.
- Never invent menu item IDs, prices, allergies, order IDs, payment state, or
  bunq state.
- Cart and checkout mutations require confirmation. If the user asks to add,
  remove, clear, update, or checkout, set `requires_confirmation` true and put
  the action in `pending_action`. Do not mark the cart mutation completed.
- Use `cart_intents` only inside `pending_action` while awaiting confirmation.
  The server will emit the final `cart_intents` only after confirmation.
- Do not create a Supabase order unless a tool workflow has explicit confirmed
  checkout context. In this app, the FastAPI adapter normally performs the final
  order creation and bunq payment after confirmation.
- If the user is asking a general question, answer from restaurant/menu/cart
  context and leave `requires_confirmation` false.
- If you cannot safely resolve an item, ask one short clarifying question.
- PAYMENT TRIGGER: Treat any of the following (and semantically equivalent
  phrases) as a checkout/payment intent — immediately set `trigger_checkout`
  true, add a `{"action": "checkout"}` cart intent inside `pending_action`,
  and set `requires_confirmation` true:
    "check out", "checkout", "pay", "pay now", "pay for this",
    "that's it", "that is it", "that's all", "that is all",
    "i'm done", "i am done", "we're done", "we are done",
    "all set", "all done", "done ordering", "done",
    "place the order", "place my order", "complete the order",
    "i'll take it", "let's go", "proceed", "finalize",
    "ready to pay", "ready to order", "bill please", "the bill",
    "wrap it up", "that will be all", "nothing else".

Return this exact JSON shape:
{
  "message": "string",
  "cart_intents": [],
  "trigger_checkout": false,
  "requires_confirmation": false,
  "pending_action": null,
  "turn_analysis": {
    "intent": "conversation|question|menu_browse|cart_update|checkout|confirm",
    "conversation_stage": "general_question|preference_capture|ordering|checkout",
    "reply_mode": "concise",
    "user_goal": "string",
    "referenced_items": [],
    "memory_update": {
      "allergies": [],
      "dietary_preferences": [],
      "likes": [],
      "dislikes": [],
      "unresolved_questions": [],
      "customer_name": "",
      "summary": ""
    },
    "output_format": {
      "style": "natural",
      "should_ask_follow_up": false,
      "should_be_brief": true
    }
  },
  "memory": {
    "allergies": [],
    "dietary_preferences": [],
    "likes": [],
    "dislikes": [],
    "unresolved_questions": [],
    "last_user_goal": "",
    "last_referenced_items": [],
    "customer_name": "",
    "summary": ""
  }
}

Each cart intent must use this shape:
{
  "action": "add_item|remove_item|update_quantity|clear_cart|checkout",
  "menu_item_id": "menu item id or null",
  "name": "menu item name or null",
  "quantity": 1,
  "modifiers": [],
  "special_instructions": null
}
""".strip()


def root_agent() -> LlmAgent:
    """Build the ADK root agent."""
    return LlmAgent(
        model=LiteLlm(model=settings.anthropic_model),
        name="echopay_restaurant_agent",
        description="Restaurant ordering, menu, cart, and payment assistant for EchoPay.",
        instruction=AGENT_INSTRUCTION,
        tools=ADK_TOOLS,
    )


async def handle_agent_turn(
    *,
    text: str,
    transcript: str,
    session_id: str,
    language: str,
    context: AgentContext,
    cart_context: list[dict[str, Any]],
    confirm_action: bool,
    fallback_context_answerer: Any = None,
) -> dict[str, Any]:
    normalized = text.strip()
    user_id = context.user.user_id if context.user else "guest"
    key = (user_id, session_id or "default")

    # Serialize turns per session so a disconnected request finishing won't
    # collide with the reconnected request. Also apply a total timeout so
    # a stuck LLM call doesn't block the session forever.
    lock = _session_lock(key)
    try:
        async with asyncio.timeout(_TURN_TIMEOUT_SECONDS):
            async with lock:
                return await _handle_agent_turn_inner(
                    normalized=normalized,
                    transcript=transcript,
                    session_id=session_id,
                    language=language,
                    context=context,
                    cart_context=cart_context,
                    confirm_action=confirm_action,
                    fallback_context_answerer=fallback_context_answerer,
                    key=key,
                )
    except TimeoutError:
        return {
            "message": "Sorry, the request took too long. Please try again.",
            "action": "none",
        }


async def _handle_agent_turn_inner(
    *,
    normalized: str,
    transcript: str,
    session_id: str,
    language: str,
    context: AgentContext,
    cart_context: list[dict[str, Any]],
    confirm_action: bool,
    fallback_context_answerer: Any = None,
    key: tuple[str, str],
) -> dict[str, Any]:
    history = list(_SESSION_MEMORY.get(key, []))
    memory_state = _SESSION_FACTS.get(key, _empty_memory_state())
    turn_analysis = _heuristic_turn_analysis(
        normalized,
        _extract_cart_intents(normalized, context.menu_items),
        memory_state,
    )
    memory_state = _merge_memory_state(memory_state, turn_analysis)
    _SESSION_FACTS[key] = memory_state

    if confirm_action or _is_confirmation(normalized):
        pending = _PENDING_ACTIONS.pop(key, None)
        if pending is not None:
            response = await _execute_pending_action(
                pending=pending,
                transcript=transcript,
                context=context,
                cart_context=cart_context,
                turn_analysis=turn_analysis,
                memory_state=memory_state,
            )
            _remember_turn(key, normalized, str(response.get("message") or ""))
            if pending.action_type == "checkout" and response.get("payment_status") == "confirmed":
                _clear_session_state(key)
            return response

    if not _can_run_adk():
        return await _fallback_turn(
            text=normalized,
            transcript=transcript,
            language=language,
            context=context,
            cart_context=cart_context,
            key=key,
            history=history,
            memory_state=memory_state,
            turn_analysis=turn_analysis,
            fallback_context_answerer=fallback_context_answerer,
        )

    prompt = _build_adk_prompt(
        text=normalized,
        transcript=transcript,
        language=language,
        context=context,
        cart_context=cart_context,
        memory_state=memory_state,
        pending_action=_PENDING_ACTIONS.get(key),
        confirm_action=confirm_action,
    )

    try:
        raw_output = await _run_adk_turn(
            user_id=user_id,
            session_id=session_id or "default",
            prompt=prompt,
            state_delta={
                "restaurant_id": str((context.restaurant or {}).get("id") or ""),
                "qr_location_id": str((context.qr_location or {}).get("id") or ""),
                "language": language,
                "memory": memory_state.to_json(),
            },
        )
        parsed = _parse_agent_json(raw_output)
    except Exception:
        return await _fallback_turn(
            text=normalized,
            transcript=transcript,
            language=language,
            context=context,
            cart_context=cart_context,
            key=key,
            history=history,
            memory_state=memory_state,
            turn_analysis=turn_analysis,
            fallback_context_answerer=fallback_context_answerer,
        )

    parsed_turn_analysis = parsed.get("turn_analysis") if isinstance(parsed.get("turn_analysis"), dict) else {}
    turn_analysis = _merge_turn_analysis(turn_analysis, parsed_turn_analysis)
    memory_state = _merge_memory_state(memory_state, turn_analysis)
    _SESSION_FACTS[key] = memory_state

    response = await _normalize_agent_response(
        parsed=parsed,
        transcript=transcript,
        language=language,
        context=context,
        key=key,
        turn_analysis=turn_analysis,
        memory_state=memory_state,
    )
    _remember_turn(key, normalized, str(response.get("message") or ""))
    return response


async def _run_adk_turn(
    *,
    user_id: str,
    session_id: str,
    prompt: str,
    state_delta: dict[str, Any],
) -> str:
    runner = _runner()
    message = types.Content(role="user", parts=[types.Part(text=prompt)])
    final_text = ""
    async for event in runner.run_async(
        user_id=user_id,
        session_id=session_id,
        new_message=message,
        state_delta=state_delta,
    ):
        event_text = _event_text(event)
        if event_text:
            final_text = event_text
    return final_text


def _runner() -> Runner:
    global _RUNNER
    if _RUNNER is None:
        _RUNNER = Runner(
            app_name=APP_NAME,
            agent=root_agent(),
            session_service=_SESSION_SERVICE,
            auto_create_session=True,
        )
    return _RUNNER


def _can_run_adk() -> bool:
    return bool(settings.anthropic_api_key and settings.anthropic_api_key != "test-key")


def _build_adk_prompt(
    *,
    text: str,
    transcript: str,
    language: str,
    context: AgentContext,
    cart_context: list[dict[str, Any]],
    memory_state: SessionMemoryState,
    pending_action: PendingAction | None,
    confirm_action: bool,
) -> str:
    return json.dumps(
        {
            "user_message": text,
            "transcript": transcript,
            "language": language,
            "confirm_action": confirm_action,
            "pending_action": pending_action.__dict__ if pending_action else None,
            "restaurant": context.restaurant or {},
            "customer": context.customer or {},
            "qr_location": context.qr_location or {},
            "menu_items": context.menu_items,
            "current_cart": cart_context,
            "recent_orders": context.recent_orders,
            "bunq_connected": context.bunq_connection is not None,
            "session_memory": memory_state.to_json(),
        },
        default=str,
    )


def _event_text(event: Any) -> str:
    content = getattr(event, "content", None)
    parts = getattr(content, "parts", None) or []
    chunks: list[str] = []
    for part in parts:
        text = getattr(part, "text", None)
        if text:
            chunks.append(str(text))
    return "\n".join(chunks).strip()


def _parse_agent_json(raw_output: str) -> dict[str, Any]:
    cleaned = raw_output.strip()
    if cleaned.startswith("```"):
        cleaned = re.sub(r"^```(?:json)?\s*", "", cleaned)
        cleaned = re.sub(r"\s*```$", "", cleaned)
    if not cleaned.startswith("{"):
        match = re.search(r"\{.*\}", cleaned, flags=re.DOTALL)
        if match:
            cleaned = match.group(0)
    parsed = json.loads(cleaned)
    if not isinstance(parsed, dict):
        raise ValueError("ADK agent returned non-object JSON.")
    return parsed


async def _normalize_agent_response(
    *,
    parsed: dict[str, Any],
    transcript: str,
    language: str,
    context: AgentContext,
    key: tuple[str, str],
    turn_analysis: dict[str, Any],
    memory_state: SessionMemoryState,
) -> dict[str, Any]:
    message = str(parsed.get("message") or parsed.get("agent_response") or "").strip()
    cart_intents = _sanitize_cart_intents(parsed.get("cart_intents"))
    pending_payload = parsed.get("pending_action") if isinstance(parsed.get("pending_action"), dict) else None
    wants_checkout = bool(parsed.get("trigger_checkout")) or any(
        intent.get("action") == "checkout" for intent in cart_intents
    )
    requires_confirmation = bool(parsed.get("requires_confirmation"))

    if pending_payload:
        pending_intents = _sanitize_cart_intents(pending_payload.get("cart_intents"))
        pending_type = str(pending_payload.get("type") or ("checkout" if wants_checkout else "cart"))
        pending_message = str(pending_payload.get("message") or message).strip()
    else:
        pending_intents = cart_intents
        pending_type = "checkout" if wants_checkout else "cart"
        pending_message = message

    if pending_intents or wants_checkout:
        requires_confirmation = True
        if not pending_message:
            pending_message = _confirmation_message(pending_intents, wants_checkout, context)
        _PENDING_ACTIONS[key] = PendingAction(
            action_type="checkout" if pending_type == "checkout" or wants_checkout else "cart",
            message=pending_message,
            cart_intents=pending_intents,
            restaurant_id=str((context.restaurant or {}).get("id") or ""),
            qr_location_id=str((context.qr_location or {}).get("id") or ""),
        )
        message = pending_message
        cart_intents = []
        pending_payload = {
            "type": _PENDING_ACTIONS[key].action_type,
            "message": pending_message,
            "cart_intents": pending_intents,
        }

    if not message:
        message = "What would you like to know or order?"

    return await _response(
        message=message,
        transcript=transcript,
        language=language,
        cart_intents=cart_intents,
        requires_confirmation=requires_confirmation,
        pending_action=pending_payload if requires_confirmation else None,
        turn_analysis=turn_analysis,
        memory_state=memory_state,
    )


async def _fallback_turn(
    *,
    text: str,
    transcript: str,
    language: str,
    context: AgentContext,
    cart_context: list[dict[str, Any]],
    key: tuple[str, str],
    history: list[ConversationTurn],
    memory_state: SessionMemoryState,
    turn_analysis: dict[str, Any],
    fallback_context_answerer: Any,
) -> dict[str, Any]:
    if _mentions_menu_introduction(text):
        message = _build_menu_introduction_response(context, category_index=0)
        if _menu_categories(context.menu_items):
            _MENU_INTRO_PROGRESS[key] = 1
        response = await _response(
            message=message,
            transcript=transcript,
            language=language,
            turn_analysis=turn_analysis,
            memory_state=memory_state,
        )
        _remember_turn(key, text, message)
        return response

    if _wants_menu_intro_continuation(text) and key in _MENU_INTRO_PROGRESS:
        category_index = _MENU_INTRO_PROGRESS[key]
        categories = _menu_categories(context.menu_items)
        message = _build_menu_introduction_response(context, category_index=category_index)
        if category_index + 1 >= len(categories):
            _MENU_INTRO_PROGRESS.pop(key, None)
        else:
            _MENU_INTRO_PROGRESS[key] = category_index + 1
        response = await _response(
            message=message,
            transcript=transcript,
            language=language,
            turn_analysis=turn_analysis,
            memory_state=memory_state,
        )
        _remember_turn(key, text, message)
        return response

    cart_intents = _extract_cart_intents(text, context.menu_items)
    wants_checkout = _mentions_checkout(text)
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
            turn_analysis=turn_analysis,
            memory_state=memory_state,
        )
        _remember_turn(key, text, pending.message)
        return response

    if fallback_context_answerer is not None:
        message = await fallback_context_answerer(
            text,
            context,
            language,
            conversation_history=history,
            cart_context=cart_context,
            memory_state=memory_state,
            turn_analysis=turn_analysis,
        )
    else:
        restaurant_name = str((context.restaurant or {}).get("name") or "this restaurant")
        safe_hint = ""
        if memory_state.allergies:
            safe_hint = f" I will keep your {', '.join(memory_state.allergies)} allergy in mind."
        message = f"I can help with {restaurant_name}'s menu, ordering, payment, and questions.{safe_hint}"
        if cart_context:
            message = "I can help adjust your current order or answer questions about the menu."
    response = await _response(
        message=message,
        transcript=transcript,
        language=language,
        turn_analysis=turn_analysis,
        memory_state=memory_state,
    )
    _remember_turn(key, text, message)
    return response


async def _execute_pending_action(
    *,
    pending: PendingAction,
    transcript: str,
    context: AgentContext,
    cart_context: list[dict[str, Any]],
    turn_analysis: dict[str, Any],
    memory_state: SessionMemoryState,
) -> dict[str, Any]:
    if pending.action_type == "cart":
        return await _response(
            message="Done. I've updated your order.",
            transcript=transcript,
            language="en",
            cart_intents=pending.cart_intents,
            action_result={"status": "completed", "type": "cart"},
            turn_analysis=turn_analysis,
            memory_state=memory_state,
        )

    if not context.bunq_connection:
        return await _response(
            message="Your order is ready, but I need you to connect bunq before I can start payment.",
            transcript=transcript,
            language="en",
            cart_intents=pending.cart_intents,
            action_result={"status": "needs_bunq_connection", "type": "payment"},
            turn_analysis=turn_analysis,
            memory_state=memory_state,
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
            turn_analysis=turn_analysis,
            memory_state=memory_state,
        )

    order_id = await supabase_context.create_order_from_cart(
        user_id=context.user.user_id if context.user else "",
        restaurant_id=pending.restaurant_id or str((context.restaurant or {}).get("id") or ""),
        qr_location_id=pending.qr_location_id or None,
        cart_items=cart_context,
    )
    total_cents = sum(
        _as_int(
            item.get("line_total"),
            _as_int(item.get("base_price"), 0) * _as_int(item.get("quantity"), 1),
        )
        for item in cart_context
    )
    # Resolve bunq token: prefers provisioned sandbox API key over OAuth token
    user_id = context.user.user_id if context.user else ""
    payment_token = await supabase_context.get_bunq_payment_token(user_id)
    if not payment_token:
        payment_token = supabase_context.decode_stored_secret(
            str((context.bunq_connection or {}).get("access_token_encrypted") or "")
        )
    if not payment_token and user_id:
        # Auto-provision a bunq sandbox account
        await customer_provisioning.provision_for(user_id)
        payment_token = await supabase_context.get_bunq_payment_token(user_id)
    payment = bunq_service.make_user_payment_from_oauth(
        oauth_access_token=payment_token,
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
        turn_analysis=turn_analysis,
        memory_state=memory_state,
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
    turn_analysis: dict[str, Any] | None = None,
    memory_state: SessionMemoryState | None = None,
) -> dict[str, Any]:
    speech = {} if settings.openai_api_key == "test-key" else await _try_synthesize_speech(message)
    intents = cart_intents or []
    trigger_checkout = any(intent.get("action") == "checkout" for intent in intents)
    memory = memory_state or _empty_memory_state()
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
        "turn_analysis": turn_analysis or _heuristic_turn_analysis(message, intents, memory),
        "memory": memory.to_json(),
        "agent_audio_base64": speech.get("agent_audio_base64", ""),
        "agent_audio_content_type": speech.get("agent_audio_content_type", "audio/wav"),
        "loop_server": "adk",
        "model": settings.anthropic_model if _can_run_adk() else "fallback",
        "language": language,
    }


def _sanitize_cart_intents(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        return []
    allowed = {"add_item", "remove_item", "update_quantity", "clear_cart", "checkout"}
    intents: list[dict[str, Any]] = []
    for item in value:
        if not isinstance(item, dict):
            continue
        action = str(item.get("action") or "").strip()
        if action not in allowed:
            continue
        intents.append(
            {
                "action": action,
                "menu_item_id": item.get("menu_item_id"),
                "name": item.get("name"),
                "quantity": max(_as_int(item.get("quantity"), 1), 1),
                "modifiers": item.get("modifiers") if isinstance(item.get("modifiers"), list) else [],
                "special_instructions": item.get("special_instructions"),
            }
        )
    return intents


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
    _SESSION_FACTS.pop(key, None)
    _MENU_INTRO_PROGRESS.pop(key, None)


def _empty_memory_state() -> SessionMemoryState:
    return SessionMemoryState(
        allergies=[],
        dietary_preferences=[],
        likes=[],
        dislikes=[],
        unresolved_questions=[],
        last_user_goal="",
        last_referenced_items=[],
        customer_name="",
        summary="",
    )


def _heuristic_turn_analysis(
    text: str,
    cart_intents: list[dict[str, Any]],
    memory_state: SessionMemoryState | None,
) -> dict[str, Any]:
    normalized = text.lower().strip()
    referenced_items = [
        str(intent.get("name") or "").strip()
        for intent in cart_intents
        if str(intent.get("name") or "").strip()
    ]
    allergies = _extract_memory_entities(normalized, ("allergic to", "allergy to"))
    dietary = _extract_memory_entities(
        normalized,
        ("i am ", "i'm ", "we are "),
        allow_prefixes={"vegan", "vegetarian", "halal", "kosher", "gluten-free"},
    )
    likes = _extract_memory_entities(normalized, ("i like", "we like", "love"))
    dislikes = _extract_memory_entities(normalized, ("i don't like", "i do not like", "hate", "dislike"))
    unresolved = [text.strip()] if "?" in text else []
    if any(word in normalized for word in ("allergic", "peanut", "vegan", "vegetarian", "gluten")):
        conversation_stage = "preference_capture"
    elif any(intent.get("action") == "checkout" for intent in cart_intents) or "pay" in normalized:
        conversation_stage = "checkout"
    elif referenced_items:
        conversation_stage = "ordering"
    else:
        conversation_stage = "general_question"

    if _is_confirmation(normalized):
        intent = "confirm"
    elif _mentions_menu_introduction(normalized):
        intent = "menu_browse"
    elif any(intent.get("action") == "checkout" for intent in cart_intents):
        intent = "checkout"
    elif referenced_items:
        intent = "cart_update"
    elif "?" in text:
        intent = "question"
    else:
        intent = "conversation"

    if referenced_items:
        user_goal = f"Order {' and '.join(referenced_items[:3])}"
    elif unresolved:
        user_goal = "Get an answer"
    elif allergies or dietary:
        user_goal = "Share dietary constraints"
    else:
        user_goal = text.strip()[:120]

    summary_parts = []
    if allergies:
        summary_parts.append(f"Allergies: {', '.join(allergies)}")
    if dietary:
        summary_parts.append(f"Dietary preferences: {', '.join(dietary)}")
    if referenced_items:
        summary_parts.append(f"Items discussed: {', '.join(referenced_items)}")
    summary = ". ".join(summary_parts)[:200]

    return {
        "intent": intent,
        "conversation_stage": conversation_stage,
        "reply_mode": "concise",
        "user_goal": user_goal,
        "referenced_items": referenced_items,
        "memory_update": {
            "allergies": allergies,
            "dietary_preferences": dietary,
            "likes": likes,
            "dislikes": dislikes,
            "unresolved_questions": unresolved,
            "customer_name": "",
            "summary": summary,
        },
        "output_format": {
            "style": "natural",
            "should_ask_follow_up": bool(unresolved or allergies or dietary),
            "should_be_brief": True,
        },
    }


def _extract_memory_entities(
    text: str,
    markers: tuple[str, ...],
    *,
    allow_prefixes: set[str] | None = None,
) -> list[str]:
    values: list[str] = []
    for marker in markers:
        if marker not in text:
            continue
        trailing = text.split(marker, maxsplit=1)[1]
        candidate = re.split(r"[,.!?]| but | and ", trailing, maxsplit=1)[0].strip()
        candidate = candidate.strip(" .,!?:;")
        if not candidate:
            continue
        if allow_prefixes is not None and candidate not in allow_prefixes:
            continue
        values.append(candidate)
    return _dedupe_strings(values)


def _merge_turn_analysis(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    merged = dict(base)
    for key, value in override.items():
        if key == "memory_update" and isinstance(value, dict):
            merged_memory = dict(base.get("memory_update") or {})
            merged_memory.update(value)
            merged[key] = merged_memory
            continue
        if key == "output_format" and isinstance(value, dict):
            merged_format = dict(base.get("output_format") or {})
            merged_format.update(value)
            merged[key] = merged_format
            continue
        merged[key] = value
    return merged


def _merge_memory_state(previous: SessionMemoryState, turn_analysis: dict[str, Any]) -> SessionMemoryState:
    update = turn_analysis.get("memory_update") if isinstance(turn_analysis, dict) else {}
    update = update if isinstance(update, dict) else {}
    summary = str(update.get("summary") or "").strip() or previous.summary
    return SessionMemoryState(
        allergies=_dedupe_strings(previous.allergies + _coerce_str_list(update.get("allergies"))),
        dietary_preferences=_dedupe_strings(
            previous.dietary_preferences + _coerce_str_list(update.get("dietary_preferences"))
        ),
        likes=_dedupe_strings(previous.likes + _coerce_str_list(update.get("likes"))),
        dislikes=_dedupe_strings(previous.dislikes + _coerce_str_list(update.get("dislikes"))),
        unresolved_questions=_dedupe_strings(
            previous.unresolved_questions + _coerce_str_list(update.get("unresolved_questions"))
        )[-6:],
        last_user_goal=str(turn_analysis.get("user_goal") or previous.last_user_goal).strip(),
        last_referenced_items=_dedupe_strings(
            _coerce_str_list(turn_analysis.get("referenced_items")) or previous.last_referenced_items
        )[-6:],
        customer_name=str(update.get("customer_name") or previous.customer_name).strip(),
        summary=summary[:240],
    )


def _coerce_str_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    return [str(item).strip() for item in value if str(item).strip()]


def _dedupe_strings(values: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        normalized = re.sub(r"\s+", " ", value).strip()
        if not normalized:
            continue
        key = normalized.lower()
        if key in seen:
            continue
        seen.add(key)
        result.append(normalized)
    return result


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


def _mentions_menu_introduction(text: str) -> bool:
    normalized = text.lower().strip()
    return "menu" in normalized and any(
        phrase in normalized
        for phrase in (
            "introduce",
            "walk me through",
            "show me around",
            "tell me about",
            "read",
            "go through",
            "explain",
            "what's on",
            "what is on",
        )
    )


def _wants_menu_intro_continuation(text: str) -> bool:
    normalized = text.lower().strip()
    return normalized in {
        "continue",
        "go on",
        "yes continue",
        "yes, continue",
        "next",
        "next category",
        "what else",
        "more",
        "tell me more",
    }


def _menu_categories(menu_items: list[dict[str, Any]]) -> list[tuple[str, list[dict[str, Any]]]]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for item in menu_items:
        name = str(item.get("name") or "").strip()
        if not name:
            continue
        category = str(item.get("category") or "Other").strip() or "Other"
        grouped.setdefault(category, []).append(item)
    return list(grouped.items())


def _build_menu_introduction_response(context: AgentContext, *, category_index: int) -> str:
    categories = _menu_categories(context.menu_items)
    if not categories:
        name = str((context.restaurant or {}).get("name") or "the restaurant")
        return f"I do not have {name}'s menu in front of me yet, but I can still help with ordering questions."

    category_index = max(0, min(category_index, len(categories) - 1))
    category, items = categories[category_index]
    item_phrases = [_format_menu_intro_item(item, context) for item in items[:4]]
    visible_items = "; ".join(phrase for phrase in item_phrases if phrase)
    remaining = len(items) - len(item_phrases)
    more_note = f" There are {remaining} more in this section." if remaining > 0 else ""
    if category_index == 0:
        opener = f"Of course. I will take it category by category. First, {category}:"
    else:
        opener = f"Next is {category}:"
    if category_index + 1 < len(categories):
        next_category = categories[category_index + 1][0]
        closer = f" Shall I continue with {next_category}?"
    else:
        closer = " That is the last category. Would you like a recommendation?"
    return f"{opener} {visible_items}.{more_note}{closer}"


def _format_menu_intro_item(item: dict[str, Any], context: AgentContext) -> str:
    name = str(item.get("name") or "").strip()
    description = str(item.get("description") or "").strip()
    price = _format_price(item.get("price"), context)
    pieces = [name]
    if description:
        pieces.append(description)
    if price:
        pieces.append(price)
    return ", ".join(pieces)


def _format_price(value: Any, context: AgentContext) -> str:
    cents = _as_int(value, -1)
    if cents < 0:
        return ""
    currency = str((context.restaurant or {}).get("currency") or "EUR").upper()
    symbol = "€" if currency == "EUR" else f"{currency} "
    return f"{symbol}{cents / 100:.2f}"


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
    normalized = text.lower()
    return any(
        phrase in normalized
        for phrase in (
            "checkout",
            "check out",
            "pay",
            "ready to order",
            "ready to pay",
            "that's all",
            "that is all",
            "that's it",
            "that is it",
            "i'm done",
            "i am done",
            "we're done",
            "we are done",
            "all set",
            "all done",
            "done ordering",
            "place the order",
            "place my order",
            "complete the order",
            "i'll take it",
            "let's go",
            "proceed",
            "finalize",
            "bill please",
            "the bill",
            "wrap it up",
            "that will be all",
            "nothing else",
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


def _as_int(value: Any, fallback: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return fallback


# Ensure LiteLLM sees the key even when Settings was loaded before ADK import.
if settings.anthropic_api_key:
    os.environ.setdefault("ANTHROPIC_API_KEY", settings.anthropic_api_key)
