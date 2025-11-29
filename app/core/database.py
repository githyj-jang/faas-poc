import sqlite3
from typing import Any, Dict, List, Optional, Tuple

DB_PATH = "database.db"

class SQLiteDB:
    def __init__(self, db_path: str = DB_PATH):
        self.db_path = db_path

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self.db_path, check_same_thread=False)

    def execute(
        self,
        query: str,
        params: Tuple = (),
        commit: bool = False,
    ) -> None:
        with self._connect() as conn:
            cur = conn.cursor()
            cur.execute(query, params)
            if commit:
                conn.commit()

    def fetch_one(
        self, query: str, params: Tuple = ()
    ) -> Optional[Tuple[Any, ...]]:
        with self._connect() as conn:
            cur = conn.cursor()
            cur.execute(query, params)
            return cur.fetchone()

    def fetch_all(
        self, query: str, params: Tuple = ()
    ) -> List[Tuple[Any, ...]]:
        with self._connect() as conn:
            cur = conn.cursor()
            cur.execute(query, params)
            return cur.fetchall()


db = SQLiteDB()
