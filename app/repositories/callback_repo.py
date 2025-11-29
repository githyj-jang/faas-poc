from datetime import datetime
from typing import Optional

from app.core.database import db


def get_callback(callback_id: int) -> Optional[dict]:
    row = db.fetch_one(
        """
        SELECT callback_id, path, method, type, code, status, updated_at
        FROM Callback WHERE callback_id=?
    """,
        (callback_id,),
    )

    if not row:
        return None

    return {
        "callback_id": row[0],
        "path": row[1],
        "method": row[2],
        "type": row[3],
        "code": row[4],
        "status": row[5],
        "updated_at": row[6],
    }


def register_callback(path: str, method: str, type: str, code: str) -> None:
    now = datetime.now()
    db.execute(
        """
        INSERT INTO Callback(path, method, type, code, status, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    """,
        (path, method, type, code, "pending", now, now),
        commit=True,
    )


def update_status(callback_id: int, status: str) -> None:
    db.execute(
        """
        UPDATE Callback SET status=?, updated_at=?
        WHERE callback_id=?
    """,
        (status, datetime.now(), callback_id),
        commit=True,
    )
