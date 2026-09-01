"""gRPC-web client for `prod_mc_billing.ConsumerUiSvc` — the "Usage Limit Reset" consumable.

The CLI billing endpoint carries no reset state; only this service does. Connect-protocol JSON
answers grpc-status 13 on this edge, so the frames are spoken as proto and hand-decoded — the
two messages are three scalar fields deep and a protobuf dependency would buy nothing.

    message ConsumerResetToken            { string token_id = 10;
                                            google.protobuf.Timestamp validity_start = 20;
                                            google.protobuf.Timestamp validity_end   = 30; }
    message ConsumerGetRemainingResetsResp { repeated ConsumerResetToken tokens = 10; }
    message ConsumerRedeemResetReq         { string token_id = 10; }
    message ConsumerRedeemResetResp        { repeated ConsumerResetToken still_redeemable = 10; }
"""

from __future__ import annotations

import http.client
import os
import struct
import urllib.error
import urllib.request

SERVICE_BASE = os.environ.get("GROK_RESETS_ENDPOINT", "https://grok.com").rstrip("/")
SERVICE_PATH = "/prod_mc_billing.ConsumerUiSvc"
DEFAULT_TIMEOUT = 6.0

TOKENS_FIELD = 10
TOKEN_ID_FIELD = 10
VALIDITY_START_FIELD = 20
VALIDITY_END_FIELD = 30
TIMESTAMP_SECONDS_FIELD = 1

WIRE_VARINT = 0
WIRE_I64 = 1
WIRE_LEN = 2
WIRE_I32 = 5

GRPC_STATUS_UNAUTHENTICATED = 16


class TransientError(Exception):
    """The call failed without saying anything about the account: no verdict may be written."""


class Weather(TransientError):
    """Capacity-shaped failure (unreachable, 429, 5xx) — the 429 taxonomy's transient class."""


class AuthError(TransientError):
    """The token was refused. Refreshable by the CLI itself, never a `needs_login`."""


class _Malformed(Exception):
    pass


def _varint(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def _read_varint(data: bytes, index: int) -> tuple[int, int]:
    shift = 0
    value = 0
    while True:
        if index >= len(data):
            raise _Malformed("varint runs past the end of the message")
        byte = data[index]
        index += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, index
        shift += 7
        if shift > 63:
            raise _Malformed("varint is longer than 64 bits")


def _fields(data: bytes) -> dict[int, list]:
    found: dict[int, list] = {}
    index = 0
    while index < len(data):
        key, index = _read_varint(data, index)
        number, wire = key >> 3, key & 7
        if wire == WIRE_VARINT:
            value, index = _read_varint(data, index)
        elif wire == WIRE_LEN:
            length, index = _read_varint(data, index)
            if index + length > len(data):
                raise _Malformed("length-delimited field runs past the end of the message")
            value = data[index:index + length]
            index += length
        elif wire in (WIRE_I64, WIRE_I32):
            width = 8 if wire == WIRE_I64 else 4
            if index + width > len(data):
                raise _Malformed("fixed-width field runs past the end of the message")
            value = data[index:index + width]
            index += width
        else:
            raise _Malformed(f"unknown wire type {wire}")
        found.setdefault(number, []).append(value)
    return found


def _seconds(raw: object) -> int | None:
    if not isinstance(raw, bytes):
        raise _Malformed("timestamp is not a message")
    value = _fields(raw).get(TIMESTAMP_SECONDS_FIELD, [None])[0]
    return value if isinstance(value, int) else None


def _token(raw: object) -> dict:
    if not isinstance(raw, bytes):
        raise _Malformed("reset token is not a message")
    fields = _fields(raw)
    token_id = fields.get(TOKEN_ID_FIELD, [None])[0]
    if not isinstance(token_id, bytes):
        raise _Malformed("reset token carries no token_id")
    start = fields.get(VALIDITY_START_FIELD, [None])[0]
    end = fields.get(VALIDITY_END_FIELD, [None])[0]
    return {
        "token_id": token_id.decode("utf-8", "replace"),
        "validity_start": _seconds(start) if start is not None else None,
        "validity_end": _seconds(end) if end is not None else None,
    }


def _tokens(message: bytes) -> list[dict]:
    return [_token(raw) for raw in _fields(message).get(TOKENS_FIELD, [])]


def _frames(body: bytes) -> tuple[bytes | None, dict[str, str]]:
    message = None
    trailers: dict[str, str] = {}
    index = 0
    while index < len(body):
        if index + 5 > len(body):
            raise _Malformed("truncated gRPC-web frame header")
        flags = body[index]
        (length,) = struct.unpack(">I", body[index + 1:index + 5])
        index += 5
        if index + length > len(body):
            raise _Malformed("truncated gRPC-web frame payload")
        payload = body[index:index + length]
        index += length
        if flags & 0x80:
            for line in payload.decode("utf-8", "replace").splitlines():
                name, separator, value = line.partition(":")
                if separator:
                    trailers[name.strip().lower()] = value.strip()
        elif message is None:
            message = payload
    return message, trailers


def _call(method: str, token: str, message: bytes, timeout: float) -> bytes:
    frame = b"\x00" + struct.pack(">I", len(message)) + message
    request = urllib.request.Request(
        SERVICE_BASE + SERVICE_PATH + "/" + method,
        data=frame,
        method="POST",
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/grpc-web+proto",
            "X-Grpc-Web": "1",
            "User-Agent": "llm-legs",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read()
            status = response.headers.get("grpc-status")
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            raise AuthError(f"HTTP {exc.code}") from None
        if exc.code == 429 or exc.code >= 500:
            raise Weather(f"HTTP {exc.code}") from None
        raise TransientError(f"HTTP {exc.code}") from None
    except urllib.error.URLError as exc:
        raise Weather(f"network error: {exc.reason}") from None
    # A connection dropped mid-body raises out of http.client, which inherits from neither OSError
    # nor URLError; uncaught it would take the whole usage poll down with the reset read.
    except (TimeoutError, OSError, http.client.HTTPException) as exc:
        raise Weather(f"network error: {exc}") from None
    try:
        payload, trailers = _frames(body)
    except _Malformed as exc:
        raise TransientError(f"unparsable reset payload: {exc}") from None
    # A trailers-only reply carries the status in the HTTP headers instead of a trailer frame,
    # and an authentication refusal arrives that way with HTTP 200.
    code = status if status is not None else trailers.get("grpc-status")
    if code not in (None, "", "0"):
        if code == str(GRPC_STATUS_UNAUTHENTICATED):
            raise AuthError(f"grpc-status {code}")
        raise TransientError(f"grpc-status {code}")
    if payload is None:
        # Neither a status nor a data frame: the service said nothing. Decoding that as an empty
        # token list would publish a `↻0` nobody measured.
        raise TransientError("reset reply carried no status and no data frame")
    return payload


def get_remaining_resets(token: str, timeout: float = DEFAULT_TIMEOUT) -> list[dict]:
    payload = _call("GetRemainingResets", token, b"", timeout)
    try:
        return _tokens(payload)
    except _Malformed as exc:
        raise TransientError(f"unparsable reset payload: {exc}") from None


def redeem_reset(token: str, token_id: str, timeout: float = DEFAULT_TIMEOUT) -> list[dict]:
    encoded = token_id.encode("utf-8")
    message = bytes([TOKEN_ID_FIELD << 3 | WIRE_LEN]) + _varint(len(encoded)) + encoded
    payload = _call("RedeemReset", token, message, timeout)
    try:
        return _tokens(payload)
    except _Malformed as exc:
        raise TransientError(f"unparsable reset payload: {exc}") from None
