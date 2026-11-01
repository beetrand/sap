# ---- Build stage -----------------------------------------------------------
# TypeScriptをJavaScriptへ変換するためだけの一時ステージ。
# npmの開発依存関係やTypeScriptソースは最終イメージへ持ち込まない。
FROM node:24.22.2-alpine3.24 AS build

# 以後のCOPY/RUNをコンテナ内の/appで実行する。
WORKDIR /app

# RDSへTLS接続するときにサーバー証明書を検証するため、AWS公式CA bundleを取得する。
# ca-certificatesはHTTPSダウンロード、curlはCA bundle取得に使用する。
RUN apk add --no-cache ca-certificates curl \
    && curl --fail --silent --show-error --location \
      https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
      --output /tmp/aws-rds-global-bundle.pem
# 依存関係ファイルを先にCOPYすることで、アプリコードだけ変わった場合に
# Docker layer cacheでnpm ciを再利用できるようにする。
COPY package.json package-lock.json ./

# lockファイルどおりに開発依存関係を含めてインストールする。
# TypeScriptコンパイラはビルド時に必要なので、このステージでは--omit=devにしない。
RUN npm ci

# コンパイル設定とTypeScriptソースをコピーし、dist/へJavaScriptを生成する。
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# ---- Runtime stage ---------------------------------------------------------
# ECSで実際に起動する最終イメージ。Build stageとは別に作り直すことで、
# TypeScriptコンパイラ、テストツール、src/を含まない小さな実行環境にする。
FROM node:24.22.2-alpine3.24 AS runtime

# Expressなどへ本番実行であることを伝える。
ENV NODE_ENV=production
WORKDIR /app

# 実行時に必要なdependenciesだけをインストールし、npm cacheも削除する。
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

# Build stageで生成したJavaScriptだけを最終イメージへコピーする。
COPY --from=build /app/dist ./dist

# PostgreSQL TLS検証用CA bundleを、アプリが参照する固定パスへコピーする。
COPY --from=build /tmp/aws-rds-global-bundle.pem /app/certs/aws-rds-global-bundle.pem

# ブラウザへ配信するHTML、CSS、JavaScript、商品画像をコピーする。
COPY public ./public

# root権限のままアプリを動かさず、Node公式イメージの非特権ユーザーへ切り替える。
USER node

# ドキュメントとしてアプリの待受ポートを示す。これだけでは外部公開されない。
EXPOSE 3000

# コンテナ内部から/healthzを確認する。失敗が続くとECSがタスクを異常と判断する。
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3000/healthz').then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))"

# コンテナ起動時に、コンパイル済みのNode.jsサーバーをPID 1として実行する。
CMD ["node", "dist/server.js"]
