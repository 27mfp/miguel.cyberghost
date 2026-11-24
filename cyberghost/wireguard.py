"""WireGuard key generation (RFC 7748 X25519) without wireguard-tools."""

import base64
import os

from .validation import validate_wireguard_key

_X25519_P = 2**255 - 19
_X25519_A24 = 121665
_X25519_BASE = (9).to_bytes(32, "little")


def _x25519_clamp(scalar):
    clamped = bytearray(scalar)
    clamped[0] &= 248
    clamped[31] &= 127
    clamped[31] |= 64
    return bytes(clamped)


def x25519(scalar, u_point):
    """RFC 7748 section 5 Montgomery ladder over Curve25519."""
    if len(scalar) != 32 or len(u_point) != 32:
        raise ValueError("X25519 inputs must be 32 bytes")
    p = _X25519_P
    k = int.from_bytes(_x25519_clamp(scalar), "little")
    x1 = int.from_bytes(u_point, "little") & ((1 << 255) - 1)
    x2, z2, x3, z3, swap = 1, 0, x1, 1, 0
    for bit in reversed(range(255)):
        k_bit = (k >> bit) & 1
        swap ^= k_bit
        if swap:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = k_bit
        a = (x2 + z2) % p
        aa = a * a % p
        b = (x2 - z2) % p
        bb = b * b % p
        e = (aa - bb) % p
        c = (x3 + z3) % p
        d = (x3 - z3) % p
        da = d * a % p
        cb = c * b % p
        x3 = (da + cb) ** 2 % p
        z3 = x1 * (da - cb) ** 2 % p
        x2 = aa * bb % p
        z2 = e * (aa + _X25519_A24 * e) % p
    if swap:
        x2, x3, z2, z3 = x3, x2, z3, z2
    return (x2 * pow(z2, p - 2, p) % p).to_bytes(32, "little")


def generate_wireguard_keys():
    """Return a fresh (private, public) WireGuard key pair as base64 strings."""
    private = _x25519_clamp(os.urandom(32))
    public = x25519(private, _X25519_BASE)
    priv = validate_wireguard_key(base64.b64encode(private).decode("ascii"))
    pub = validate_wireguard_key(base64.b64encode(public).decode("ascii"))
    return priv, pub
