# FaaS Gateway

Function as a Service Gateway API 프로젝트

## 📁 프로젝트 구조

```
faas-test/
├── app/                           # 메인 애플리케이션
│   ├── __init__.py
│   ├── main.py                    # FastAPI 앱 설정
│   ├── core/
│   │   ├── __init__.py
│   │   └── database.py            # DB 관리 클래스
│   ├── models/
│   │   ├── __init__.py
│   │   ├── callback_model.py      # 콜백 데이터 모델
│   │   └── lambda_model.py        # Lambda 상태 코드 Enum
│   ├── repositories/
│   │   ├── __init__.py
│   │   └── callback_repo.py       # 콜백 데이터 저장소
│   ├── routers/
│   │   ├── __init__.py
│   │   ├── api.py                 # API 라우터 (/api/{path})
│   │   └── deploy.py              # 배포 라우터 (/callback/deploy)
│   ├── utils/
│   │   ├── __init__.py
│   │   └── docker_utils.py        # Docker 빌드/실행 유틸
│   ├── scripts/
│   │   ├── __init__.py
│   │   ├── init_db.py             # DB 초기화 스크립트
│   │   └── init_test.py           # 테스트 데이터 스크립트
│   └── runtime/                   # Lambda 런타임 템플릿
│       ├── python/
│       └── node/
├── docker/
│   └── docker-compose.yaml
├── main.py                        # 서버 진입점
├── setup.py                       # DB 셋업 스크립트
├── require.txt                    # 의존성
├── start.sh                       # 시작 스크립트
└── database.db                    # SQLite 데이터베이스 (자동 생성)
```

## 🚀 시작하기

### 1. 의존성 설치

```bash
pip install -r require.txt
```

### 2. 데이터베이스 초기화

#### 옵션 1: setup.py 사용 (권장)
```bash
python setup.py
```

#### 옵션 2: 개별 스크립트 실행
```bash
# DB 스키마 생성
python -m app.scripts.init_db

# 테스트 데이터 삽입
python -m app.scripts.init_test
```

### 3. 서버 실행

```bash
python main.py
```

또는:

```bash
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

## 📚 API 엔드포인트

### 콜백 배포
- **POST** `/callback/deploy` - 콜백 배포 또는 언배포

### 콜백 실행
- **GET/POST** `/api/{path_name}` - 콜백 함수 실행

### 헬스 체크
- **GET** `/health` - 서버 상태 확인

## 🛠️ 개발 가이드

### 데이터 모델
- `app/models/callback_model.py`: 콜백 요청/응답 모델
- `app/models/lambda_model.py`: Lambda 상태 코드 Enum

### 데이터베이스
- `app/core/database.py`: SQLiteDB 클래스 (쿼리 실행)
- `app/repositories/callback_repo.py`: 데이터 접근 계층

### 라우터
- `app/routers/deploy.py`: 배포 관련 엔드포인트
- `app/routers/api.py`: 콜백 실행 엔드포인트

### 유틸리티
- `app/utils/docker_utils.py`: Docker 이미지 빌드/컨테이너 실행

## 📝 코드 규칙

- **스타일**: PEP 8 (Black 포매터 준수)
- **타입 힌팅**: 모든 함수에 타입 지정
- **문서화**: 모든 함수/클래스에 Docstring 작성
- **로깅**: `print()` 대신 `logging` 모듈 사용
- **상태 코드**: `LambdaStatusCode` Enum 사용

## 📋 스크립트 설명

### init_db.py
- 데이터베이스 스키마 생성
- Callback, ChatRoom, Chats 테이블 생성
- 이미 존재하는 경우 건너뜀 (IF NOT EXISTS)

### init_test.py
- 테스트용 콜백 데이터 2개 삽입
- Python Lambda 함수 (callback_id: 1001)
- Node.js Lambda 함수 (callback_id: 1002)

### setup.py
- 데이터베이스 초기화 및 테스트 데이터 로드
- 일괄 설정을 위한 편의 스크립트

## 🐛 트러블슈팅

### 데이터베이스 재초기화
```bash
rm database.db
python setup.py
```

### 로그 레벨 확인
- 로그는 `logging` 모듈을 통해 출력됩니다
- Docker 컨테이너 실행 로그도 포함됩니다
