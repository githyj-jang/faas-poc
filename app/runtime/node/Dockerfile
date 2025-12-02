FROM node:18

WORKDIR /app

# package.json 복사 및 의존성 설치
COPY package.json ./
RUN npm install

COPY . .

CMD ["node", "index.js"]
