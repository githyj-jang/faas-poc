#!/bin/bash

# 간단한 CURL 테스트: library와 env를 포함한 콜백 생성 테스트

BASE_URL="http://localhost:8000"

echo "=== Simple Test: Python Callback with Library & Env ==="
echo ""

# 1. Python 콜백 생성
echo "1. Python 콜백 생성"
echo "---"
curl -X POST "$BASE_URL/callbacks/" \
  -H "Content-Type: application/json" \
  -d '{
    "path": "simple_python",
    "method": "POST",
    "type": "python",
    "code": "import os\nimport json\n\ndef handler(event):\n    db_url = os.environ.get(\"DB_URL\", \"not_set\")\n    api_key = os.environ.get(\"API_KEY\", \"not_set\")\n    \n    return {\n        \"statusCode\": 200,\n        \"body\": json.dumps({\n            \"message\": \"Success\",\n            \"db_url\": db_url,\n            \"api_key\": api_key,\n            \"event\": event\n        })\n    }",
    "library": "requests==2.28.0",
    "env": {
      "DB_URL": "postgresql://localhost:5432/testdb",
      "API_KEY": "test_api_key_123"
    }
  }' | jq .

echo ""
echo ""

# 2. Node.js 콜백 생성
echo "2. Node.js 콜백 생성"
echo "---"
curl -X POST "$BASE_URL/callbacks/" \
  -H "Content-Type: application/json" \
  -d '{
    "path": "simple_nodejs",
    "method": "POST",
    "type": "node",
    "code": "exports.handler = async (event) => {\n  const dbUrl = process.env.DB_URL || \"not_set\";\n  const apiKey = process.env.API_KEY || \"not_set\";\n  \n  return {\n    statusCode: 200,\n    body: JSON.stringify({\n      message: \"Success\",\n      db_url: dbUrl,\n      api_key: apiKey,\n      event: event\n    })\n  };\n};",
    "library": "{\"name\": \"test\", \"version\": \"1.0.0\", \"dependencies\": {\"axios\": \"^1.3.0\"}}",
    "env": {
      "DB_URL": "mongodb://localhost:27017/testdb",
      "API_KEY": "node_api_key_456"
    }
  }' | jq .

echo ""
echo ""

# 3. 콜백 조회
echo "3. 생성된 콜백 조회 (ID=1)"
echo "---"
curl -X GET "$BASE_URL/callbacks/1" | jq .

echo ""
echo ""

# 4. 콜백 업데이트
echo "4. 콜백 환경변수 업데이트 (ID=1)"
echo "---"
curl -X PUT "$BASE_URL/callbacks/1" \
  -H "Content-Type: application/json" \
  -d '{
    "env": {
      "DB_URL": "postgresql://updated-host:5432/newdb",
      "API_KEY": "updated_key_789",
      "LOG_LEVEL": "DEBUG"
    }
  }' | jq .

echo ""
