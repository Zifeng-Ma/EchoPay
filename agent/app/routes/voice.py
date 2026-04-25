"""Voice payment request endpoints backed by OpenAI transcription and analysis."""

from __future__ import annotations

import json
from base64 import b64encode
from dataclasses import dataclass
from typing import Any

import httpx
from fastapi import APIRouter, File, Form, HTTPException, UploadFile
from pydantic import BaseModel, Field

from app.config import settings

router = APIRouter(tags=["voice"])


class TranscriptDraftRequest(BaseModel):
    transcript: str
    conversation_context: str = ""
    speaker_turns: list[dict[str, Any]] = Field(default_factory=list)
    turn_count: int = Field(default=1, ge=1)


@dataclass(slots=True)
class SpeakerTurn:
    speaker_label: str
    text: str
    start_seconds: float | None = None
    end_seconds: float | None = None

    def to_json(self) -> dict[str, Any]:
        return {
            "speaker_label": self.speaker_label,
            "text": self.text,
            "start_seconds": self.start_seconds,
            "end_seconds": self.end_seconds,
        }


@dataclass(slots=True)
class TranscriptionResult:
    transcript: str
    speaker_turns: list[SpeakerTurn]

_ORDER_SCHEMA: dict[str, Any] = {
    "type": "object",
    "additionalProperties": False,
    "required": [
        "short_summary",
        "final_confirmation",
        "needs_confirmation",
        "payment_ready",
        "contradictions",
        "order_items",
        "merchant_name",
        "customer_name",
        "payment_amount",
        "currency",
        "payment_reason",
        "speaker_insights",
        "split_requested",
        "split_summary",
        "split_payment_requests",
        "agent_response",
        "session_status",
        "should_call_human_server",
        "handoff_reason",
        "user_type",
        "hesitation_detected",
        "turn_count",
        "turn_limit_reached",
    ],
    "properties": {
        "short_summary": {"type": "string"},
        "final_confirmation": {"type": "string"},
        "needs_confirmation": {"type": "boolean"},
        "payment_ready": {"type": "boolean"},
        "contradictions": {
            "type": "array",
            "items": {"type": "string"},
        },
        "merchant_name": {"type": "string"},
        "customer_name": {"type": "string"},
        "payment_amount": {"type": "string"},
        "currency": {"type": "string"},
        "payment_reason": {"type": "string"},
        "order_items": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": ["name", "quantity", "notes"],
                "properties": {
                    "name": {"type": "string"},
                    "quantity": {"type": "integer", "minimum": 1},
                    "notes": {"type": "string"},
                },
            },
        },
        "speaker_insights": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": [
                    "speaker_label",
                    "role",
                    "display_name",
                    "needs_help",
                    "help_reason",
                ],
                "properties": {
                    "speaker_label": {"type": "string"},
                    "role": {"type": "string"},
                    "display_name": {"type": "string"},
                    "needs_help": {"type": "boolean"},
                    "help_reason": {"type": "string"},
                },
            },
        },
        "split_requested": {"type": "boolean"},
        "split_summary": {"type": "string"},
        "split_payment_requests": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": [
                    "speaker_label",
                    "customer_name",
                    "amount",
                    "currency",
                    "payment_reason",
                    "order_items",
                ],
                "properties": {
                    "speaker_label": {"type": "string"},
                    "customer_name": {"type": "string"},
                    "amount": {"type": "string"},
                    "currency": {"type": "string"},
                    "payment_reason": {"type": "string"},
                    "order_items": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "additionalProperties": False,
                            "required": ["name", "quantity", "notes"],
                            "properties": {
                                "name": {"type": "string"},
                                "quantity": {"type": "integer", "minimum": 1},
                                "notes": {"type": "string"},
                            },
                        },
                    },
                },
            },
        },
        "agent_response": {"type": "string"},
        "session_status": {
            "type": "string",
            "enum": ["ordering", "confirming", "payment_ready", "needs_human", "completed"],
        },
        "should_call_human_server": {"type": "boolean"},
        "handoff_reason": {"type": "string"},
        "user_type": {"type": "string"},
        "hesitation_detected": {"type": "boolean"},
        "turn_count": {"type": "integer", "minimum": 1},
        "turn_limit_reached": {"type": "boolean"},
    },
}

_SYSTEM_PROMPT = """
You are a voice checkout assistant for bunq-style payment requests.

Your job:
1. Read the current transcript and any prior conversation context.
2. Produce a very short spoken-style summary of what should be charged.
3. Detect contradictions, replacements, cancellations, or uncertainty.
4. Build the best current draft of the purchase and payment request.
5. Ask a concise confirmation question that focuses on conflicts when needed.
6. Infer who is speaking when possible and whether any speaker sounds confused or needs help.
7. If multiple customers are clearly ordering separately or asking to split, prepare split payment request drafts.

Rules:
- Treat the transcript as a merchant and customer conversation about what should be paid.
- Prefer the latest instruction when someone corrects themselves.
- If the speaker says "actually" or changes an item, keep only the corrected item.
- Do not invent items, totals, names, or fees.
- If the transcript is too vague to charge someone safely, keep `payment_ready` false and ask for the missing details.
- Keep `short_summary` to 1-2 short sentences.
- Keep `final_confirmation` short, natural, and ready to read back aloud.
- Put only real conflicts or ambiguities in `contradictions`.
- Use `merchant_name` and `customer_name` only when clearly stated, otherwise return an empty string.
- Put the explicit payable amount in `payment_amount` using plain decimal text like `11.50`. If no reliable amount is stated, return an empty string.
- Use `currency` with an ISO-like code such as `EUR`. Default to `EUR` when the conversation clearly implies euros, otherwise return an empty string.
- Set `payment_ready` to true only when there is enough information to create a draft payment request, especially a reliable amount.
- `payment_reason` should be a short label like `Cafe purchase`, `Lunch tab`, or `Market checkout`.
- If there are no contradictions, return an empty array and still confirm the payment request.
- `notes` should capture modifiers such as size, no onions, extra spicy, etc.
- `speaker_insights` should map each speaker label to the most likely role such as `customer`, `server`, `merchant`, or `unknown`.
- Set `needs_help` to true only when a speaker sounds confused, uncertain, lost, or directly asks for help or clarification.
- Keep `help_reason` short and concrete, such as `Unsure who ordered which drink` or `Asked how to split the bill`.
- Set `split_requested` to true when multiple customers want separate payment requests or when separate customer-owned orders are clear enough to split safely.
- `split_summary` should be one short sentence. Leave it empty when no split is relevant.
- `split_payment_requests` should only include customer-facing payment drafts that are actually supported by the transcript. If the split is mentioned but amounts are unclear, include the customer and items with an empty `amount`.
- `agent_response` is the short natural-language response the app can show or speak.
- Set `session_status` to `needs_human` when the customer asks for a person, sounds stuck, or the request is too ambiguous or conflicted to continue safely.
- Set `should_call_human_server` true only when `session_status` is `needs_human`.
- `handoff_reason` must be a short customer-facing explanation when human help is needed, otherwise empty.
- Set `turn_limit_reached` true when the provided turn count is 4 or greater and the order still cannot be completed safely.
- Return JSON only.
""".strip()

_TTS_INSTRUCTIONS = (
    "Speak as a concise, calm checkout assistant. Keep the tone warm and clear. "
    "Do not add extra details beyond the provided response."
)


@router.post("/voice-order")
async def create_voice_order(
    audio: UploadFile = File(...),
    conversation_context: str = Form(default=""),
    language: str = Form(default="en"),
    turn_count: int = Form(default=1),
) -> dict[str, Any]:
    """Transcribe an audio clip and turn it into a payment request draft."""
    audio_bytes = await audio.read()
    if not audio_bytes:
        raise HTTPException(status_code=400, detail="Audio upload was empty.")

    transcription = await _transcribe_audio(
        filename=audio.filename or "voice-order.m4a",
        content_type=audio.content_type or "audio/m4a",
        audio_bytes=audio_bytes,
        language=language,
    )

    analysis = await _analyze_order(
        transcript=transcription.transcript,
        speaker_turns=transcription.speaker_turns,
        conversation_context=conversation_context,
        turn_count=max(turn_count, 1),
    )
    speech = await _try_synthesize_speech(_agent_speech_text(analysis))

    return {
        "transcript": transcription.transcript,
        "speaker_turns": [turn.to_json() for turn in transcription.speaker_turns],
        **analysis,
        **speech,
    }


@router.post("/payment-draft")
async def create_payment_draft_from_transcript(
    request: TranscriptDraftRequest,
) -> dict[str, Any]:
    """Analyze a provided transcript and return a payment request draft."""
    transcript = request.transcript.strip()
    if not transcript:
        raise HTTPException(status_code=400, detail="Transcript cannot be empty.")

    analysis = await _analyze_order(
        transcript=transcript,
        speaker_turns=[
            SpeakerTurn(
                speaker_label=(turn.get("speaker_label") or turn.get("speaker") or "Speaker 1")
                .strip(),
                text=(turn.get("text") or "").strip(),
                start_seconds=_as_float(turn.get("start_seconds") or turn.get("start")),
                end_seconds=_as_float(turn.get("end_seconds") or turn.get("end")),
            )
            for turn in request.speaker_turns
            if (turn.get("text") or "").strip()
        ],
        conversation_context=request.conversation_context,
        turn_count=request.turn_count,
    )

    return {
        "transcript": transcript,
        "speaker_turns": request.speaker_turns,
        **analysis,
    }


async def _transcribe_audio(
    *,
    filename: str,
    content_type: str,
    audio_bytes: bytes,
    language: str,
) -> TranscriptionResult:
    diarized = await _run_diarized_transcription(
        filename=filename,
        content_type=content_type,
        audio_bytes=audio_bytes,
        language=language,
    )
    if diarized is not None:
        return diarized

    transcript = await _run_plain_transcription(
        model=settings.openai_transcription_model,
        filename=filename,
        content_type=content_type,
        audio_bytes=audio_bytes,
        language=language,
    )

    if transcript:
        return TranscriptionResult(transcript=transcript, speaker_turns=[])

    # Fallback to Whisper if the primary model returns an empty transcript.
    fallback_transcript = await _run_plain_transcription(
        model="whisper-1",
        filename=filename,
        content_type=content_type,
        audio_bytes=audio_bytes,
        language=language,
    )

    if fallback_transcript:
        return fallback_transcript

    raise HTTPException(
        status_code=502,
        detail=(
            "OpenAI transcription returned no text. This usually means the clip "
            "contained silence, the microphone input was too weak, or the simulator "
            "did not provide usable audio."
        ),
    )


async def _run_transcription(
    *,
    model: str,
    filename: str,
    content_type: str,
    audio_bytes: bytes,
    language: str,
) -> str:
    return await _run_plain_transcription(
        model=model,
        filename=filename,
        content_type=content_type,
        audio_bytes=audio_bytes,
        language=language,
    )


async def _run_diarized_transcription(
    *,
    filename: str,
    content_type: str,
    audio_bytes: bytes,
    language: str,
) -> TranscriptionResult | None:
    async with httpx.AsyncClient(timeout=90.0) as client:
        response = await client.post(
            "https://api.openai.com/v1/audio/transcriptions",
            headers={"Authorization": f"Bearer {settings.openai_api_key}"},
            data={
                "model": settings.openai_diarization_model,
                "language": language,
                "response_format": "diarized_json",
                "chunking_strategy": "auto",
            },
            files={
                "file": (filename, audio_bytes, content_type),
            },
        )

    if response.status_code >= 400:
        return None

    payload = response.json()
    segments = payload.get("segments", []) if isinstance(payload, dict) else []
    speaker_turns: list[SpeakerTurn] = []
    transcript_chunks: list[str] = []

    for index, segment in enumerate(segments):
        if not isinstance(segment, dict):
            continue
        text = str(segment.get("text") or "").strip()
        if not text:
            continue
        speaker_label = _normalize_speaker_label(
            segment.get("speaker"),
            fallback_index=index,
        )
        speaker_turns.append(
            SpeakerTurn(
                speaker_label=speaker_label,
                text=text,
                start_seconds=_as_float(segment.get("start")),
                end_seconds=_as_float(segment.get("end")),
            )
        )
        transcript_chunks.append(f"{speaker_label}: {text}")

    transcript = " ".join(transcript_chunks).strip()
    if not transcript:
        transcript = str(payload.get("text") or "").replace("\n", " ").strip()

    if not transcript:
        return None

    return TranscriptionResult(
        transcript=transcript,
        speaker_turns=speaker_turns,
    )


async def _run_plain_transcription(
    *,
    model: str,
    filename: str,
    content_type: str,
    audio_bytes: bytes,
    language: str,
) -> str:
    async with httpx.AsyncClient(timeout=90.0) as client:
        response = await client.post(
            "https://api.openai.com/v1/audio/transcriptions",
            headers={"Authorization": f"Bearer {settings.openai_api_key}"},
            data={
                "model": model,
                "language": language,
                "response_format": "text",
            },
            files={
                "file": (filename, audio_bytes, content_type),
            },
        )

    if response.status_code >= 400:
        raise HTTPException(
            status_code=502,
            detail=f"OpenAI transcription failed: {response.text}",
        )

    transcript = response.text.strip()
    return transcript.replace("\n", " ").strip()


async def _analyze_order(
    *,
    transcript: str,
    speaker_turns: list[SpeakerTurn],
    conversation_context: str,
    turn_count: int = 1,
) -> dict[str, Any]:
    speaker_turns_text = _stringify_speaker_turns(speaker_turns)
    user_prompt = (
        "Conversation context:\n"
        f"{conversation_context.strip() or 'No prior context.'}\n\n"
        "Detected speaker turns:\n"
        f"{speaker_turns_text or 'No diarized turns available.'}\n\n"
        "New transcript:\n"
        f"{transcript}\n\n"
        "Current turn count:\n"
        f"{turn_count}\n\n"
        "Return the safest payment draft you can. If the amount or payment details are incomplete, "
        "leave unknown fields empty and ask a concise follow-up question."
    )

    payload = {
        "model": settings.openai_order_model,
        "input": [
            {
                "role": "system",
                "content": [{"type": "input_text", "text": _SYSTEM_PROMPT}],
            },
            {
                "role": "user",
                "content": [{"type": "input_text", "text": user_prompt}],
            },
        ],
        "text": {
            "format": {
                "type": "json_schema",
                "name": "voice_order_review",
                "strict": True,
                "schema": _ORDER_SCHEMA,
            }
        },
    }

    async with httpx.AsyncClient(timeout=90.0) as client:
        response = await client.post(
            "https://api.openai.com/v1/responses",
            headers={
                "Authorization": f"Bearer {settings.openai_api_key}",
                "Content-Type": "application/json",
            },
            json=payload,
        )

    if response.status_code >= 400:
        raise HTTPException(
            status_code=502,
            detail=f"OpenAI order analysis failed: {response.text}",
        )

    response_json = response.json()
    output_text = _extract_output_text(response_json)
    if not output_text:
        raise HTTPException(
            status_code=502,
            detail="OpenAI order analysis returned no output text.",
        )

    try:
        parsed = json.loads(output_text)
    except json.JSONDecodeError as exc:
        raise HTTPException(
            status_code=502,
            detail="OpenAI order analysis returned invalid JSON.",
        ) from exc

    parsed["turn_count"] = max(turn_count, 1)
    parsed["turn_limit_reached"] = bool(parsed.get("turn_limit_reached")) or (
        turn_count >= 4 and parsed.get("session_status") != "payment_ready"
    )
    return parsed


def _agent_speech_text(analysis: dict[str, Any]) -> str:
    for key in ("handoff_reason", "agent_response", "final_confirmation", "short_summary"):
        value = str(analysis.get(key) or "").strip()
        if value:
            return value
    return ""


async def _try_synthesize_speech(text: str) -> dict[str, str]:
    trimmed = text.strip()
    if not trimmed:
        return {}

    try:
        audio_bytes = await _synthesize_speech(trimmed)
    except HTTPException:
        return {}
    except httpx.HTTPError:
        return {}

    if not audio_bytes:
        return {}

    return {
        "agent_audio_base64": b64encode(audio_bytes).decode("ascii"),
        "agent_audio_content_type": "audio/wav",
    }


async def _synthesize_speech(text: str) -> bytes:
    async with httpx.AsyncClient(timeout=90.0) as client:
        response = await client.post(
            "https://api.openai.com/v1/audio/speech",
            headers={
                "Authorization": f"Bearer {settings.openai_api_key}",
                "Content-Type": "application/json",
            },
            json={
                "model": settings.openai_tts_model,
                "voice": settings.openai_tts_voice,
                "input": text,
                "instructions": _TTS_INSTRUCTIONS,
                "response_format": "wav",
            },
        )

    if response.status_code >= 400:
        raise HTTPException(
            status_code=502,
            detail=f"OpenAI speech synthesis failed: {response.text}",
        )

    return response.content


def _stringify_speaker_turns(speaker_turns: list[SpeakerTurn]) -> str:
    if not speaker_turns:
        return ""

    lines: list[str] = []
    for turn in speaker_turns:
        time_window = ""
        if turn.start_seconds is not None and turn.end_seconds is not None:
            time_window = f" [{turn.start_seconds:.1f}s-{turn.end_seconds:.1f}s]"
        elif turn.start_seconds is not None:
            time_window = f" [{turn.start_seconds:.1f}s]"
        lines.append(f"{turn.speaker_label}{time_window}: {turn.text}")
    return "\n".join(lines)


def _normalize_speaker_label(raw_label: Any, *, fallback_index: int) -> str:
    label = str(raw_label or "").strip()
    if not label:
        return f"Speaker {fallback_index + 1}"
    if label.lower().startswith("speaker_"):
        try:
            numeric = int(label.split("_", maxsplit=1)[1])
        except (ValueError, IndexError):
            return label.replace("_", " ").title()
        return f"Speaker {numeric + 1}"
    return label.replace("_", " ").title()


def _as_float(value: Any) -> float | None:
    try:
        return None if value is None else float(value)
    except (TypeError, ValueError):
        return None


def _extract_output_text(payload: dict[str, Any]) -> str:
    """Extract plain text from a Responses API payload."""
    chunks: list[str] = []
    for output_item in payload.get("output", []):
        if output_item.get("type") != "message":
            continue
        for content_item in output_item.get("content", []):
            if content_item.get("type") == "output_text":
                chunks.append(content_item.get("text", ""))
    return "".join(chunks).strip()
