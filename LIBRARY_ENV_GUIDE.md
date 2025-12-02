# Library & Environment Variables 기능 가이드

## 개요

콜백에 `library`(라이브러리)와 `env`(환경변수) 필드를 추가하여 더욱 유연한 배포 환경을 지원합니다.

### 주요 기능

1. **library**: Python의 `requirements.txt` 또는 Node.js의 `package.json` 내용
   - Python: pip로 자동 설치
   - Node.js: npm으로 자동 설치

2. **env**: JSON 형식의 환경변수
   - Docker 컨테이너 실행 시 `-e` 플래그로 전달
   - Kubernetes Pod 실행 시 환경변수로 설정

---

## 1. 데이터베이스 스키마

### callback_info 테이블 추가 필드

```sql
-- 추가된 필드
library VARCHAR -- 라이브러리 (requirements.txt 또는 package.json)
env JSON       -- 환경변수 (JSON 형식)
```

### 모델 정의

```python
class CallbackInfo(Base):
    # ... 기존 필드 ...
    library = Column(String, nullable=True)  # 라이브러리
    env = Column(JSON, nullable=True)        # 환경변수
```

---

## 2. API 엔드포인트

### 콜백 생성 (POST /callbacks/)

```bash
curl -X POST "http://localhost:8000/callbacks/" \
  -H "Content-Type: application/json" \
  -d '{
    "path": "my_function",
    "method": "POST",
    "type": "python",
    "code": "...",
    "library": "requests==2.28.0\nflask==2.2.0",
    "env": {
      "API_KEY": "my_secret_key",
      "DB_URL": "postgresql://user:pass@db:5432/mydb"
    }
  }'
```

**요청 필드:**
- `path`: 콜백 경로 (필수)
- `method`: HTTP 메서드 (필수)
- `type`: 런타임 타입 - "python" 또는 "node" (필수)
- `code`: 콜백 코드 (필수)
- `library`: 라이브러리 (선택사항)
  - Python: newline으로 구분된 requirements 목록
  - Node.js: package.json 형식의 JSON 문자열
- `env`: 환경변수 (선택사항, JSON 객체)
- `chat_id`: 챗룸 ID (선택사항)

**응답:**
```json
{
  "callback_id": 1,
  "path": "my_function",
  "method": "POST",
  "type": "python",
  "library": "requests==2.28.0\nflask==2.2.0",
  "env": {
    "API_KEY": "my_secret_key",
    "DB_URL": "postgresql://user:pass@db:5432/mydb"
  },
  "status": "pending",
  "updated_at": "2024-12-02T10:00:00"
}
```

### 콜백 조회 (GET /callbacks/{callback_id})

```bash
curl -X GET "http://localhost:8000/callbacks/1"
```

### 콜백 업데이트 (PUT /callbacks/{callback_id})

```bash
curl -X PUT "http://localhost:8000/callbacks/1" \
  -H "Content-Type: application/json" \
  -d '{
    "library": "requests==2.30.0\ndjango==4.2.0",
    "env": {
      "API_KEY": "new_secret_key",
      "DB_URL": "postgresql://newuser:newpass@newdb:5432/newdb",
      "LOG_LEVEL": "DEBUG"
    }
  }'
```

---

## 3. 런타임 템플릿 구조

### Python (app/runtime/python/)

```
python/
├── Dockerfile           # requirements.txt 자동 감지
├── main.py             # 진입점
├── runner.py           # 런타임 로직
└── requirements.txt    # 기본 의존성 (선택사항)
```

**Dockerfile:**
```dockerfile
FROM python:3.10

WORKDIR /app
COPY . .

# requirements.txt가 있으면 설치
RUN if [ -f requirements.txt ]; then pip install -r requirements.txt; else pip install requests; fi

CMD ["python", "main.py"]
```

### Node.js (app/runtime/node/)

```
node/
├── Dockerfile      # package.json 자동 감지
├── index.js        # 진입점
├── runner.js       # 런타임 로직
└── package.json    # 기본 의존성 (선택사항)
```

**Dockerfile:**
```dockerfile
FROM node:18

WORKDIR /app

# package.json이 있으면 npm install 실행
COPY package.json ./
RUN npm install

COPY . .

CMD ["node", "index.js"]
```

---

## 4. 빌드 프로세스

### Python 콜백 빌드

1. **진입점 파일 생성**: `lambda_function.py` 생성
2. **라이브러리 파일 생성**: `requirements.txt` 생성 (library 필드 있으면)
3. **런타임 파일 복사**: `main.py`, `runner.py` 등 복사
4. **Docker 빌드**: 이미지 빌드 시작
5. **의존성 설치**: `pip install -r requirements.txt` 실행

### Node.js 콜백 빌드

1. **진입점 파일 생성**: `lambda_function.js` 생성
2. **package.json 파일 생성**: `package.json` 생성 (library 필드 있으면)
3. **런타임 파일 복사**: `index.js`, `runner.js` 등 복사
4. **Docker 빌드**: 이미지 빌드 시작
5. **의존성 설치**: `npm install` 실행

---

## 5. 실행 시 환경변수 처리

### Docker 실행

```bash
docker run \
  -e SESSION_ID=abc123 \
  -e EVENT='{"test":"data"}' \
  -e API_KEY='my_secret_key' \
  -e DB_URL='postgresql://user:pass@db:5432/mydb' \
  callback_1
```

### Kubernetes 실행

```yaml
containers:
  - name: lambda-container
    image: callback_1
    env:
      - name: SESSION_ID
        value: "abc123"
      - name: EVENT
        value: '{"test":"data"}'
      - name: API_KEY
        value: "my_secret_key"
      - name: DB_URL
        value: "postgresql://user:pass@db:5432/mydb"
```

---

## 6. 테스트 스크립트 사용법

### 스크립트 실행

```bash
./test_callback_with_library_env.sh
```

### 스크립트 기능

1. **Python 콜백 생성**: library와 env 포함
2. **Node.js 콜백 생성**: library와 env 포함
3. **콜백 조회**: 생성된 콜백 정보 확인
4. **콜백 배포**: Docker로 배포 시작
5. **콜백 실행**: 배포된 콜백 실행 (환경변수 포함)
6. **콜백 업데이트**: 환경변수 수정

---

## 7. 예제 코드

### Python 예제

```python
# 요청
{
  "path": "data_processor",
  "method": "POST",
  "type": "python",
  "code": """
import os
import json
import requests

def handler(event):
    api_key = os.environ.get('API_KEY')
    db_url = os.environ.get('DB_URL')
    
    # requests 라이브러리 사용
    response = requests.get(
        'https://api.example.com/data',
        headers={'Authorization': f'Bearer {api_key}'}
    )
    
    return {
        'statusCode': 200,
        'body': json.dumps({
            'data': response.json(),
            'db_url': db_url
        })
    }
""",
  "library": "requests==2.28.0\npython-dotenv==0.19.0",
  "env": {
    "API_KEY": "sk_test_123456789",
    "DB_URL": "postgresql://user:pass@db:5432/mydb"
  }
}
```

### Node.js 예제

```javascript
// 요청
{
  "path": "notification_sender",
  "method": "POST",
  "type": "node",
  "code": """
const axios = require('axios');

exports.handler = async (event) => {
  const apiKey = process.env.API_KEY;
  const webhookUrl = process.env.WEBHOOK_URL;
  
  try {
    const response = await axios.post(webhookUrl, event, {
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json'
      }
    });
    
    return {
      statusCode: 200,
      body: JSON.stringify({
        message: 'Notification sent',
        data: response.data
      })
    };
  } catch (error) {
    return {
      statusCode: 500,
      body: JSON.stringify({ error: error.message })
    };
  }
};
""",
  "library": "{\"name\":\"notifier\",\"version\":\"1.0.0\",\"dependencies\":{\"axios\":\"^1.3.0\",\"dotenv\":\"^16.0.3\"}}",
  "env": {
    "API_KEY": "sk_test_987654321",
    "WEBHOOK_URL": "https://webhook.example.com/events"
  }
}
```

---

## 8. 주의사항

### library 필드 형식

- **Python**: 각 패키지를 newline으로 구분
  ```
  requests==2.28.0
  flask==2.2.0
  python-dotenv==0.19.0
  ```

- **Node.js**: 전체 package.json 내용을 문자열로
  ```json
  {
    "name": "my-lambda",
    "version": "1.0.0",
    "dependencies": {
      "axios": "^1.3.0",
      "express": "^4.18.2"
    }
  }
  ```

### env 필드 주의사항

1. **민감한 정보**: 프로덕션 환경에서는 시크릿 관리 도구 사용 권장
2. **크기 제한**: 너무 큰 환경변수는 docker/k8s 제약이 있을 수 있음
3. **특수 문자**: JSON 형식이므로 특수 문자는 이스케이프 필요

### 보안 권장사항

1. 환경변수에는 민감한 정보 저장 피하기
2. 시크릿 관리 시스템(Vault, AWS Secrets Manager 등) 사용
3. 콜백 코드에서 os.environ 접근 시 기본값 설정

---

## 9. 문제 해결

### 라이브러리 설치 실패

**증상**: Docker 빌드 실패

**해결**:
1. library 필드 형식 확인
2. 패키지명과 버전 정확성 확인
3. 플랫폼 호환성 확인

### 환경변수 미적용

**증상**: 콜백에서 환경변수 조회 불가

**해결**:
1. env 필드가 정확히 설정되었는지 확인
2. 콜백 코드에서 `os.environ.get()` (Python) 또는 `process.env` (Node.js) 사용 확인
3. 기본값 설정

---

## 10. 참고 자료

- [Python requirements.txt 형식](https://pip.pypa.io/en/stable/reference/requirements-file-format/)
- [Node.js package.json](https://docs.npmjs.com/cli/v9/configuring-npm/package-json)
- [Docker ENV 변수](https://docs.docker.com/engine/reference/builder/#env)
- [Kubernetes Environment Variables](https://kubernetes.io/docs/tasks/inject-data-application/define-environment-variable-container/)
