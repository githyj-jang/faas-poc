FROM python:3.10

WORKDIR /app
COPY . .

# requirements.txt가 있으면 설치
RUN if [ -f requirements.txt ]; then pip install -r requirements.txt; else pip install requests; fi

CMD ["python", "main.py"]
