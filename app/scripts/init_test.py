"""
테스트 데이터 초기화 스크립트

데이터베이스에 테스트용 콜백 데이터를 삽입합니다.
"""

import sqlite3
from datetime import datetime
from pathlib import Path

# 프로젝트 루트 디렉토리
PROJECT_ROOT = Path(__file__).parent.parent.parent
DB_PATH = PROJECT_ROOT / "database.db"

# Lambda 코드 문자열
PYTHON_LAMBDA_CODE = """
import json

def lambda_handler(event, context):
    message = event.get("message", "Hello from lambda")
    return {
        "statusCode": 200,
        "body": json.dumps({"reply": message})
    }
"""

NODE_LAMBDA_CODE = """
exports.lambda_handler = async (event, context) => {
    return { msg: "Hello Node", event };
};
"""

# 테스트 데이터
TEST_CALLBACKS = [
    {
        "callback_id": 1001,
        "path": "hello",
        "method": "GET",
        "type": "python",
        "code": PYTHON_LAMBDA_CODE,
        "status": "not_deployed",
    },
    {
        "callback_id": 1002,
        "path": "world",
        "method": "GET",
        "type": "node",
        "code": NODE_LAMBDA_CODE,
        "status": "not_deployed",
    },
]


def init_test_data() -> None:
    """
    테스트 데이터 초기화

    데이터베이스에 테스트용 콜백 데이터를 삽입합니다.
    """
    conn = sqlite3.connect(str(DB_PATH))
    try:
        cur = conn.cursor()
        now = datetime.utcnow().isoformat()

        for callback in TEST_CALLBACKS:
            cur.execute(
                """
                INSERT OR REPLACE INTO Callback (
                    callback_id, path, method, type, code, status, 
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
                (
                    callback["callback_id"],
                    callback["path"],
                    callback["method"],
                    callback["type"],
                    callback["code"],
                    callback["status"],
                    now,
                    now,
                ),
            )

        conn.commit()
        print(
            f"✓ Test data inserted successfully. "
            f"({len(TEST_CALLBACKS)} callbacks)"
        )
    except sqlite3.Error as e:
        print(f"✗ Test data insertion failed: {e}")
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    init_test_data()
