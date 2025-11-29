"""
데이터베이스 초기화 스크립트

SQLite 데이터베이스 스키마를 생성합니다.
"""

import sqlite3
from pathlib import Path

# 프로젝트 루트 디렉토리
PROJECT_ROOT = Path(__file__).parent.parent.parent
DB_PATH = PROJECT_ROOT / "database.db"

SCHEMA = """
CREATE TABLE IF NOT EXISTS Callback (
    callback_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    path            TEXT NOT NULL,
    method          TEXT NOT NULL,
    type            TEXT NOT NULL,
    code            TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending',
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS ChatRoom (
    chat_room_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    title           TEXT,
    created_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS Chats (
    chat_id         INTEGER PRIMARY KEY AUTOINCREMENT,
    chats           TEXT,
    chat_room_id    INTEGER,
    created_at      TEXT NOT NULL,
    FOREIGN KEY(chat_room_id) REFERENCES ChatRoom(chat_room_id)
);
"""


def init_database() -> None:
    """
    SQLite 데이터베이스 초기화

    스키마를 실행하여 테이블을 생성합니다.
    """
    conn = sqlite3.connect(str(DB_PATH))
    try:
        cur = conn.cursor()
        cur.executescript(SCHEMA)
        conn.commit()
        print(f"✓ SQLite DB initialized successfully at {DB_PATH}")
    except sqlite3.Error as e:
        print(f"✗ Database initialization failed: {e}")
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    init_database()
