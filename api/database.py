"""
Supabase database operations.
Все IP адреса хранятся зашифрованными (Fernet AES).
Для поиска по IP используется SHA-256 хэш.
"""

import os
import uuid
from datetime import datetime, date, timezone
from typing import Optional
from supabase import create_client, Client
from .crypto import encrypt_ip, decrypt_ip, hash_ip

_client: Optional[Client] = None


def _db() -> Client:
    global _client
    if _client is None:
        _client = create_client(
            os.environ["SUPABASE_URL"],
            os.environ["SUPABASE_KEY"],
        )
    return _client


# ═══════════════════════════════════════
# CLIENTS
# ═══════════════════════════════════════

def create_client_record(label: str = "", note: str = "") -> dict:
    token = uuid.uuid4().hex[:16]
    data = {"token": token, "label": label, "note": note}
    result = _db().table("clients").insert(data).execute()
    row = result.data[0]
    return {"id": row["id"], "token": row["token"], "label": label, "note": note}


def get_client_by_token(token: str) -> Optional[dict]:
    result = _db().table("clients").select("*").eq("token", token).execute()
    if not result.data:
        return None
    return _decrypt_client(result.data[0])


def get_client_by_id(client_id: int) -> Optional[dict]:
    result = _db().table("clients").select("*").eq("id", client_id).execute()
    if not result.data:
        return None
    return _decrypt_client(result.data[0])


def list_clients(include_blocked: bool = True) -> list[dict]:
    query = _db().table("clients").select("*").order("id")
    if not include_blocked:
        query = query.eq("is_blocked", False)
    result = query.execute()
    return [_decrypt_client(r) for r in result.data]


def activate_client(token: str, new_ip: str, user_agent: str = "") -> dict:
    """Главная логика активации: проверки + обновление IP."""
    client = get_client_by_token(token)
    if not client:
        return {"error": "invalid_token"}
    if client["is_blocked"]:
        return {"error": "blocked"}

    max_act = int(os.environ.get("MAX_ACTIVATIONS_PER_DAY", "10"))
    today = date.today().isoformat()

    # Сброс счётчика если новый день
    activations_today = client["_activations_today"]
    if client["_reset_date"] != today:
        activations_today = 0

    if max_act > 0 and activations_today >= max_act:
        return {"error": "daily_limit"}

    old_ip = client["current_ip"]

    # Тот же IP — ничего не делаем
    if old_ip == new_ip:
        return {"status": "already_active", "client_id": client["id"], "new_ip": new_ip}

    # Обновляем клиента
    now = datetime.now(timezone.utc).isoformat()
    update_data = {
        "previous_ip_enc": client["_raw_current_ip_enc"],
        "current_ip_enc": encrypt_ip(new_ip),
        "current_ip_hash": hash_ip(new_ip),
        "last_activated_at": now,
        "activations_today": activations_today + 1,
        "activations_reset_date": today,
    }
    _db().table("clients").update(update_data).eq("id", client["id"]).execute()

    # Лог активации
    _db().table("activation_log").insert({
        "client_id": client["id"],
        "ip_enc": encrypt_ip(new_ip),
        "user_agent": user_agent[:500] if user_agent else None,
    }).execute()

    return {
        "status": "activated",
        "client_id": client["id"],
        "old_ip": old_ip,
        "new_ip": new_ip,
    }


def block_client(client_id: int, blocked: bool = True):
    _db().table("clients").update({"is_blocked": blocked}).eq("id", client_id).execute()


def delete_client(client_id: int) -> Optional[dict]:
    """Удаляет клиента, возвращает его данные (с расшифрованным IP)."""
    client = get_client_by_id(client_id)
    if not client:
        return None
    _db().table("activation_log").delete().eq("client_id", client_id).execute()
    _db().table("clients").delete().eq("id", client_id).execute()
    return client


def get_activation_logs(client_id: int, limit: int = 50) -> list[dict]:
    result = (
        _db().table("activation_log")
        .select("*")
        .eq("client_id", client_id)
        .order("created_at", desc=True)
        .limit(limit)
        .execute()
    )
    logs = []
    for r in result.data:
        ip = None
        if r.get("ip_enc"):
            try:
                ip = decrypt_ip(r["ip_enc"])
            except Exception:
                ip = "decrypt_error"
        logs.append({
            "id": r["id"],
            "ip": ip,
            "user_agent": r.get("user_agent"),
            "created_at": r["created_at"],
        })
    return logs


def get_all_active_ips() -> list[str]:
    """Все незаблокированные IP для полной синхронизации."""
    result = (
        _db().table("clients")
        .select("current_ip_enc")
        .eq("is_blocked", False)
        .not_.is_("current_ip_enc", "null")
        .execute()
    )
    ips = []
    for r in result.data:
        try:
            ips.append(decrypt_ip(r["current_ip_enc"]))
        except Exception:
            pass
    return ips


def _decrypt_client(row: dict) -> dict:
    """Расшифровывает IP-поля, убирает enc-столбцы."""
    current_ip = None
    previous_ip = None
    if row.get("current_ip_enc"):
        try:
            current_ip = decrypt_ip(row["current_ip_enc"])
        except Exception:
            current_ip = "decrypt_error"
    if row.get("previous_ip_enc"):
        try:
            previous_ip = decrypt_ip(row["previous_ip_enc"])
        except Exception:
            previous_ip = "decrypt_error"

    return {
        "id": row["id"],
        "token": row["token"],
        "label": row["label"],
        "note": row.get("note", ""),
        "current_ip": current_ip,
        "previous_ip": previous_ip,
        "last_activated_at": row["last_activated_at"],
        "activations_today": row["activations_today"],
        "is_blocked": row["is_blocked"],
        "created_at": row["created_at"],
        # Приватные поля для внутреннего использования
        "_activations_today": row["activations_today"],
        "_reset_date": row.get("activations_reset_date"),
        "_raw_current_ip_enc": row.get("current_ip_enc"),
    }


# ═══════════════════════════════════════
# RELAYS
# ═══════════════════════════════════════

def add_relay(name: str, host: str, agent_port: int = 7580,
              agent_secret: str = "") -> dict:
    data = {
        "name": name, "host": host,
        "agent_port": agent_port, "agent_secret": agent_secret,
    }
    result = _db().table("relays").insert(data).execute()
    return result.data[0]


def list_relays() -> list[dict]:
    result = _db().table("relays").select("*").order("id").execute()
    return result.data


def get_active_relays() -> list[dict]:
    result = (
        _db().table("relays")
        .select("*")
        .eq("is_active", True)
        .execute()
    )
    return result.data


def delete_relay(relay_id: int) -> bool:
    result = _db().table("relays").delete().eq("id", relay_id).execute()
    return len(result.data) > 0


def toggle_relay(relay_id: int, active: bool):
    _db().table("relays").update({"is_active": active}).eq("id", relay_id).execute()


def mark_relay_synced(relay_id: int, synced: bool):
    _db().table("relays").update({"is_synced": synced}).eq("id", relay_id).execute()


def update_relay_health(relay_id: int, health_data: dict):
    _db().table("relays").update({
        "last_health": health_data,
        "last_health_at": datetime.now(timezone.utc).isoformat(),
    }).eq("id", relay_id).execute()
