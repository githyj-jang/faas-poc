# Library & Environment Variables 기능 구현 요약

## 📋 구현 완료 항목

### 1. ✅ 데이터베이스 모델 업데이트
- **파일**: `app/core/models.py`
- **변경사항**:
  - `CallbackInfo` 모델에 2개 필드 추가
  - `library` (String): 라이브러리 정보 저장
  - `env` (JSON): 환경변수 저장

### 2. ✅ Pydantic 스키마 업데이트
- **파일**: `app/models/callback_model.py`
- **변경사항**:
  - `CallbackRegisterRequest`: `library`, `env` 필드 추가
  - `CallbackUpdateRequest`: `library`, `env` 필드 추가
  - `CallbackResponse`: `library`, `env` 필드 추가

### 3. ✅ Repository 계층 업데이트
- **파일**: `app/repositories/callback_repo.py`
- **변경사항**:
  - `create_callback()`: `library`, `env` 매개변수 추가
  - 콜백 생성 시 라이브러리와 환경변수 저장

### 4. ✅ Docker 유틸리티 업데이트
- **파일**: `app/utils/docker_utils.py`
- **변경사항**:
  - `run_callback_container()`: `env_vars` 매개변수 추가
  - 실행 시 환경변수를 Docker `-e` 플래그로 전달
  - `build_callback_image_background()`: 빌드 시 라이브러리 파일 생성
    - Python: `requirements.txt` 생성 후 `pip install -r requirements.txt`
    - Node.js: `package.json` 생성 후 `npm install`

### 5. ✅ Kubernetes 유틸리티 업데이트
- **파일**: `app/utils/kube_utils.py`
- **변경사항**:
  - `run_lambda_job()`: `env_vars` 매개변수 추가
  - Kubernetes Pod 생성 시 환경변수 설정

### 6. ✅ 라우터 업데이트
- **파일**: `app/routers/callback.py`
- **변경사항**:
  - POST `/callbacks/`: `library`, `env` 필드 처리
  - PUT `/callbacks/{callback_id}`: `library`, `env` 필드 업데이트

### 7. ✅ 런타임 템플릿 업데이트
- **파일**: 
  - `app/runtime/python/Dockerfile`
  - `app/runtime/node/Dockerfile`
- **변경사항**:
  - Python: `requirements.txt` 자동 감지 및 설치
  - Node.js: `package.json` 자동 감지 및 설치

### 8. ✅ 테스트 스크립트 생성
- **파일**:
  - `test_callback_with_library_env.sh`: 전체 기능 테스트
  - `simple_test.sh`: 간단한 기본 테스트
- **기능**:
  - Python/Node.js 콜백 생성
  - 라이브러리 및 환경변수 포함
  - 콜백 조회, 업데이트, 배포 테스트

### 9. ✅ 문서 작성
- **파일**:
  - `LIBRARY_ENV_GUIDE.md`: 상세 사용 가이드
  - `IMPLEMENTATION_SUMMARY.md`: 이 파일

---

## 🔄 동작 흐름

### 콜백 생성 흐름
```
POST /callbacks/
  ↓
CallbackRegisterRequest 검증
  ↓
CallbackRepository.create_callback() 호출
  ↓
  ├─ library, env 데이터 저장
  └─ 콜백 생성 완료
  ↓
CallbackResponse 반환
```

### 콜백 배포 흐름
```
POST /callback/deploy
  ↓
콜백 상태 → "build"
  ↓
build_callback_image_background() (백그라운드)
  ├─ 진입점 파일 생성 (lambda_function.py/.js)
  ├─ library 필드가 있으면:
  │  ├─ Python: requirements.txt 생성
  │  └─ Node.js: package.json 생성
  ├─ 런타임 파일 복사
  ├─ Docker 빌드
  │  ├─ Python: pip install -r requirements.txt
  │  └─ Node.js: npm install
  └─ 완료 시 status="deployed"
```

### 콜백 실행 흐름 (환경변수 포함)
```
GET/POST /api/{path_name}
  ↓
run_callback_container(image, env_vars)
  ├─ Docker 명령어 구성
  │  ├─ docker run
  │  ├─ -e SESSION_ID=...
  │  ├─ -e EVENT=...
  │  ├─ -e API_KEY=... (env_vars에서)
  │  ├─ -e DB_URL=... (env_vars에서)
  │  └─ -e ... (모든 env 항목)
  ├─ 컨테이너 실행
  └─ 결과 반환
```

---

## 📝 API 예제

### 1. 라이브러리와 환경변수 포함한 콜백 생성

#### Python
```bash
curl -X POST "http://localhost:8000/callbacks/" \
  -H "Content-Type: application/json" \
  -d '{
    "path": "data_processor",
    "method": "POST",
    "type": "python",
    "code": "import os\nimport requests\n\ndef handler(event):\n    api_key = os.environ.get(\"API_KEY\")\n    return {\"statusCode\": 200, \"body\": \"OK\"}",
    "library": "requests==2.28.0\npandas==1.5.0",
    "env": {
      "API_KEY": "secret_key_123",
      "DB_URL": "postgresql://db:5432/mydb"
    }
  }'
```

**응답:**
```json
{
  "callback_id": 1,
  "path": "data_processor",
  "method": "POST",
  "type": "python",
  "library": "requests==2.28.0\npandas==1.5.0",
  "env": {
    "API_KEY": "secret_key_123",
    "DB_URL": "postgresql://db:5432/mydb"
  },
  "status": "pending",
  "updated_at": "2024-12-02T10:00:00"
}
```

#### Node.js
```bash
curl -X POST "http://localhost:8000/callbacks/" \
  -H "Content-Type: application/json" \
  -d '{
    "path": "webhook_handler",
    "method": "POST",
    "type": "node",
    "code": "exports.handler = async (event) => {\n  const key = process.env.API_KEY;\n  return {statusCode: 200, body: \"OK\"};\n};",
    "library": "{\"dependencies\": {\"axios\": \"^1.3.0\"}}",
    "env": {
      "MODE": "PRODUCTION"
    }
  }'
```

### 2. 환경변수 업데이트

```bash
curl -X PUT "http://localhost:8000/callbacks/1" \
  -H "Content-Type: application/json" \
  -d '{
    "env": {
      "API_KEY": "updated_key_789",
      "LOG_LEVEL": "DEBUG"
    }
  }'
```

### 3. 콜백 배포

```bash
curl -X POST "http://localhost:8000/callback/deploy" \
  -H "Content-Type: application/json" \
  -d '{
    "callback_id": 1,
    "status": true,
    "c_type": "docker"
  }'
```

### 4. 배포된 콜백 실행 (환경변수 자동 전달)

```bash
curl -X POST "http://localhost:8000/api/data_processor" \
  -H "Content-Type: application/json" \
  -d '{"input": "test_data"}'
```

---

## 🧪 테스트 방법

### 전체 기능 테스트
```bash
./test_callback_with_library_env.sh
```

### 간단한 테스트
```bash
./simple_test.sh
```

### 수동 테스트
```bash
# 1. 콜백 생성
curl -X POST "http://localhost:8000/callbacks/" ...

# 2. 배포
curl -X POST "http://localhost:8000/callback/deploy" ...

# 3. 실행
curl -X POST "http://localhost:8000/api/your_path" ...
```

---

## 🔧 환경변수 처리 방식

### Python에서 접근
```python
import os

# 기본값과 함께 가져오기
api_key = os.environ.get("API_KEY", "default_value")

# 필수 환경변수
db_url = os.environ["DB_URL"]  # 없으면 KeyError
```

### Node.js에서 접근
```javascript
// 기본값과 함께 가져오기
const apiKey = process.env.API_KEY || "default_value";

// 필수 환경변수
const dbUrl = process.env.DB_URL;  // 없으면 undefined
```

---

## 📚 library 필드 형식

### Python
```
requests==2.28.0
flask==2.2.0
python-dotenv==0.19.0
```

### Node.js
```json
{
  "name": "my-function",
  "version": "1.0.0",
  "dependencies": {
    "axios": "^1.3.0",
    "express": "^4.18.2"
  }
}
```

---

## 🔒 보안 고려사항

1. **환경변수 노출 주의**
   - 민감한 정보는 별도 시크릿 관리 도구 사용 권장
   - 로그에 환경변수 값이 노출되지 않도록 주의

2. **라이브러리 버전 고정**
   - `requests==2.28.0` (고정)
   - ~~`requests>=2.28.0`~~ (변동 위험)

3. **패키지 신뢰성**
   - 신뢰할 수 있는 패키지만 사용
   - 정기적 보안 업데이트

---

## 📊 파일 변경 요약

| 파일 | 변경 내용 | 줄 수 |
|------|---------|-------|
| `app/core/models.py` | `library`, `env` 필드 추가 | +2 |
| `app/models/callback_model.py` | 3개 스키마 업데이트 | +8 |
| `app/repositories/callback_repo.py` | `library`, `env` 매개변수 처리 | +3 |
| `app/utils/docker_utils.py` | 라이브러리 파일 생성, env 변수 전달 | +40 |
| `app/utils/kube_utils.py` | `env_vars` 매개변수 추가 | +8 |
| `app/routers/callback.py` | `library`, `env` 처리 | +4 |
| `app/runtime/python/Dockerfile` | `requirements.txt` 자동 설치 | +1 |
| `app/runtime/node/Dockerfile` | `package.json` 자동 감지 | +0 |
| `test_callback_with_library_env.sh` | 전체 기능 테스트 | 130 |
| `simple_test.sh` | 간단한 테스트 | 60 |
| `LIBRARY_ENV_GUIDE.md` | 상세 가이드 | 400 |

---

## ✨ 주요 특징

1. **자동 의존성 설치**: library 필드만으로 자동으로 패키지 설치
2. **환경변수 자동 전달**: env 필드의 모든 환경변수가 런타임에 전달됨
3. **Docker/Kubernetes 모두 지원**: 두 환경 모두에서 동일한 방식으로 동작
4. **유연한 업데이트**: 콜백 생성 후 언제든 환경변수 수정 가능
5. **보안**: 환경변수는 JSON으로 저장되어 보안 강화

---

## 🚀 다음 개선 사항 (Optional)

1. **시크릿 관리 연동**: AWS Secrets Manager, HashiCorp Vault 등과 통합
2. **환경변수 암호화**: 데이터베이스에 저장 전 암호화
3. **라이브러리 캐싱**: 자주 사용되는 라이브러리는 미리 빌드된 이미지 사용
4. **다중 환경**: dev, staging, production 환경별 환경변수 관리
5. **환경변수 검증**: 필수 환경변수 정의 및 검증

---

## 📞 문제 해결

### 라이브러리 설치 실패
- 패키지 이름과 버전 확인
- 인터넷 연결 확인
- 패키지 호환성 확인

### 환경변수가 적용되지 않음
- `env` 필드가 정확히 설정되었는지 확인
- 콜백 코드에서 올바른 방식으로 접근하는지 확인
- 기본값 설정

### Docker 빌드 실패
- Docker 서비스 실행 여부 확인
- 디스크 용량 확인
- 로그 메시지 확인

---

## 📖 참고 링크

- [Python requirements.txt](https://pip.pypa.io/en/stable/reference/requirements-file-format/)
- [Node.js package.json](https://docs.npmjs.com/cli/v9/configuring-npm/package-json)
- [Docker ENV](https://docs.docker.com/engine/reference/builder/#env)
- [Kubernetes Env](https://kubernetes.io/docs/tasks/inject-data-application/define-environment-variable-container/)
