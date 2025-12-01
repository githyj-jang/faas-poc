import os
import json
import requests
from runner import execute_lambda

SESSION_ID = os.environ.get("SESSION_ID")
EVENT = os.environ.get("EVENT")

event_obj = json.loads(EVENT.replace("'", '"'))

# Lambda
result = execute_lambda(event_obj, {})

#print(f"[Lambda] SESSION_ID={SESSION_ID}, result={json.dumps(result, indent=2)}")

print(f"{json.dumps(result)}")

'''
file_path = "lambda_function.py"

try:
    with open(file_path, "r", encoding="utf-8") as f:
        code = f.read()
    print("=== lambda_function.py 내용 ===")
    print(code)
except FileNotFoundError:
    print(f"파일이 존재하지 않습니다: {file_path}")

# Gateway callback endpoint (Redis)
try:
    response = requests.post(
        f"http://host.docker.internal:8000/callback/{SESSION_ID}",
        json=result,
        timeout=5
    )
    print(f"[Lambda] POST response: {response.status_code}, {response.text}")
    print(f"{json.dumps(result)}")
except requests.exceptions.RequestException as e:
    # print(f"[Lambda] POST failed: {e}")
    print(f"{json.dumps(result)}")
'''