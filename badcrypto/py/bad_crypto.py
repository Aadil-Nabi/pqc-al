"""Deliberately mixed crypto for the CBOM scan (pyca/cryptography)."""
import hashlib
import os

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa, ec, padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


# --- findings the scan should raise ---

def md5_digest(data: bytes) -> bytes:
    return hashlib.md5(data).digest()                     # broken


def sha1_digest(data: bytes) -> bytes:
    h = hashes.Hash(hashes.SHA1())                        # deprecated
    h.update(data)
    return h.finalize()


def tripledes(data: bytes) -> bytes:
    key = b"0123456789abcdef01234567"                     # hardcoded
    c = Cipher(algorithms.TripleDES(key), modes.ECB())    # 3DES + ECB
    e = c.encryptor()
    return e.update(data) + e.finalize()


def weak_rsa():
    return rsa.generate_private_key(public_exponent=65537, key_size=1024)


def rsa_2048_encrypt(data: bytes) -> bytes:
    k = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    return k.public_key().encrypt(
        data, padding.OAEP(padding.MGF1(hashes.SHA256()), hashes.SHA256(), None)
    )


def ecdsa_sign(data: bytes) -> bytes:
    k = ec.generate_private_key(ec.SECP256R1())           # Shor-broken
    return k.sign(data, ec.ECDSA(hashes.SHA256()))


# --- the one correct path, for contrast ---

def aes_gcm(data: bytes) -> bytes:
    key = AESGCM.generate_key(bit_length=256)             # Grover-weakened only
    nonce = os.urandom(12)
    return nonce + AESGCM(key).encrypt(nonce, data, None)
