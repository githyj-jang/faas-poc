#!/bin/bash

# 테스트 스크립트: library와 env를 포함한 콜백 생성 및 배포

BASE_URL="http://localhost:8000"

# 색상 정의
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Callback Library & Env Test ===${NC}\n"

# 1. Python 콜백 - library와 env 포함해서 생성
echo -e "${YELLOW}1. Python 콜백 생성 (library, env 포함)${NC}"
PYTHON_CALLBACK=$(curl -s -X POST "$BASE_URL/callbacks/" \
  -H "Content-Type: application/json" \
  -d '{
    "path": "python_test",
    "method": "POST",
    "type": "python",
    "code": "import os\nimport json\n\ndef handler(event):\n    # 환경변수 사용\n    api_key = os.environ.get(\"API_KEY\", \"default\")\n    db_url = os.environ.get(\"DB_URL\", \"default\")\n    \n    # requests 라이브러리 사용\n    import requests\n    \n    return {\n        \"statusCode\": 200,\n        \"body\": json.dumps({\n            \"message\": \"Python handler executed\",\n            \"api_key\": api_key,\n            \"db_url\": db_url,\n            \"event\": event\n        })\n    }",
    "library": "requests==2.28.0\nflask==2.2.0",
    "env": {
      "API_KEY": "my_secret_key_12345",
      "DB_URL": "postgresql://user:pass@db:5432/mydb",
      "LOG_LEVEL": "INFO"
    }
  }')

echo "$PYTHON_CALLBACK" | jq .
PYTHON_ID=$(echo "$PYTHON_CALLBACK" | jq -r '.callback_id')
echo -e "${GREEN}✓ Python 콜백 생성 완료 (ID: $PYTHON_ID)${NC}\n"

# 2. Node.js 콜백 - library와 env 포함해서 생성
echo -e "${YELLOW}2. Node.js 콜백 생성 (library, env 포함)${NC}"
NODE_CALLBACK=$(curl -s -X POST "$BASE_URL/callbacks/" \
  -H "Content-Type: application/json" \
  -d '{
    "path": "nodejs_test",
    "method": "POST",
    "type": "node",
    "code": "const axios = require(\"axios\");\n\nexports.handler = async (event) => {\n  const apiKey = process.env.API_KEY || \"default\";\n  const dbUrl = process.env.DB_URL || \"default\";\n  const logLevel = process.env.LOG_LEVEL || \"INFO\";\n  \n  return {\n    statusCode: 200,\n    body: JSON.stringify({\n      message: \"Node.js handler executed\",\n      api_key: apiKey,\n      db_url: dbUrl,\n      log_level: logLevel,\n      event: event\n    })\n  };\n};",
    "library": "{\"name\": \"lambda-handler\",\"version\": \"1.0.0\",\"dependencies\": {\"axios\": \"^1.3.0\",\"express\": \"^4.18.2\"}}",
    "env": {
      "API_KEY": "node_secret_key_67890",
      "DB_URL": "mongodb://user:pass@mongo:27017/mydb",
      "LOG_LEVEL": "DEBUG",
      "NODE_ENV": "production"
    }
  }')

echo "$NODE_CALLBACK" | jq .
NODE_ID=$(echo "$NODE_CALLBACK" | jq -r '.callback_id')
echo -e "${GREEN}✓ Node.js 콜백 생성 완료 (ID: $NODE_ID)${NC}\n"

# 3. 콜백 조회
echo -e "${YELLOW}3. 생성된 콜백 조회${NC}"
echo "Python 콜백 조회:"
curl -s -X GET "$BASE_URL/callbacks/$PYTHON_ID" | jq .
echo ""
echo "Node.js 콜백 조회:"
curl -s -X GET "$BASE_URL/callbacks/$NODE_ID" | jq .
echo ""

# 4. Python 콜백 배포
echo -e "${YELLOW}4. Python 콜백 배포 (Docker)${NC}"
DEPLOY_REQUEST=$(cat <<EOF
{
  "callback_id": $PYTHON_ID,
  "status": true,
  "c_type": "docker"
}
EOF
)

DEPLOY_RESULT=$(curl -s -X POST "$BASE_URL/callback/deploy" \
  -H "Content-Type: application/json" \
  -d "$DEPLOY_REQUEST")

echo "$DEPLOY_RESULT" | jq .
echo -e "${GREEN}✓ Python 콜백 배포 시작 (상태 변경됨)${NC}\n"

# 5. Node.js 콜백 배포
echo -e "${YELLOW}5. Node.js 콜백 배포 (Docker)${NC}"
DEPLOY_REQUEST=$(cat <<EOF
{
  "callback_id": $NODE_ID,
  "status": true,
  "c_type": "docker"
}
EOF
)

DEPLOY_RESULT=$(curl -s -X POST "$BASE_URL/callback/deploy" \
  -H "Content-Type: application/json" \
  -d "$DEPLOY_REQUEST")

echo "$DEPLOY_RESULT" | jq .
echo -e "${GREEN}✓ Node.js 콜백 배포 시작 (상태 변경됨)${NC}\n"

# 6. 콜백 실행 (env 포함)
echo -e "${YELLOW}6. 배포된 콜백 실행 (환경변수 포함)${NC}"

# 잠시 대기 (빌드 완료 대기)
echo "빌드 완료 대기 중..."
sleep 3

echo "Python 콜백 실행:"
curl -s -X POST "$BASE_URL/api/python_test" \
  -H "Content-Type: application/json" \
  -d '{"test": "data"}' | jq .
echo ""

echo "Node.js 콜백 실행:"
curl -s -X POST "$BASE_URL/api/nodejs_test" \
  -H "Content-Type: application/json" \
  -d '{"test": "data"}' | jq .
echo ""

# 7. 콜백 업데이트 (env 수정)
echo -e "${YELLOW}7. 콜백 업데이트 (환경변수 수정)${NC}"
UPDATE_RESULT=$(curl -s -X PUT "$BASE_URL/callbacks/$PYTHON_ID" \
  -H "Content-Type: application/json" \
  -d '{
    "env": {
      "API_KEY": "updated_key_11111",
      "DB_URL": "postgresql://newuser:newpass@newdb:5432/newdb",
      "LOG_LEVEL": "WARNING"
    }
  }')

echo "$UPDATE_RESULT" | jq .
echo -e "${GREEN}✓ Python 콜백 환경변수 업데이트 완료${NC}\n"

echo -e "${BLUE}=== 테스트 완료 ===${NC}"
echo -e "\n${YELLOW}참고:${NC}"
echo "- Python: requirements.txt 자동 생성 (pip install -r requirements.txt)"
echo "- Node.js: package.json 자동 생성 (npm install)"
echo "- 환경변수는 Docker 실행 시 -e 플래그로 자동 전달됨"
echo "- library 필드는 문자열 형식 (requirements.txt 또는 package.json 내용)"
