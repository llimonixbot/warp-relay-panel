import hashlib
import os
from cryptography.fernet import Fernet

_fernet = None


def _get_fernet() -> Fernet:
    global _fernet
    if _fernet is None:
        key = os.environ["ENCRYPTION_KEY"]
        _fernet = Fernet(key.encode())
    return _fernet


def encrypt_ip(ip: str) -> str:
    return _get_fernet().encrypt(ip.encode()).decode()


def decrypt_ip(encrypted: str) -> str:
    return _get_fernet().decrypt(encrypted.encode()).decode()


def hash_ip(ip: str) -> str:
    return hashlib.sha256(ip.encode()).hexdigest()
