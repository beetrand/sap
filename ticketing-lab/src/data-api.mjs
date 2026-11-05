// Workflow用LambdaからAuroraへ接続する共通Module。
// TCP ConnectionではなくRDS Data APIへHTTPS Requestを送る。
import {
  BeginTransactionCommand,
  CommitTransactionCommand,
  ExecuteStatementCommand,
  RDSDataClient,
  RollbackTransactionCommand,
} from "@aws-sdk/client-rds-data";

// Lambda Containerが再利用された時にClientも再利用する。
const client = new RDSDataClient({});

// Terraformが各Lambdaへ渡す接続情報。Password本体は環境変数へ入れない。
const baseRequest = {
  resourceArn: process.env.DB_CLUSTER_ARN,
  secretArn: process.env.DB_SECRET_ARN,
  database: process.env.DB_NAME,
};

// SQLを実行し、Column名付きJSONとして結果を受け取る。
export async function execute(sql, parameters = [], transactionId) {
  return client.send(
    new ExecuteStatementCommand({
      ...baseRequest,
      sql,
      parameters,
      transactionId,
      includeResultMetadata: true,
      formatRecordsAs: "JSON",
    }),
  );
}

// Data APIのJSON文字列を通常のJavaScript配列へ変換する。
export function rows(result) {
  return result.formattedRecords ? JSON.parse(result.formattedRecords) : [];
}

// 複数SQLを全部成功または全部失敗にするTransaction Helper。
export async function withTransaction(work) {
  const begun = await client.send(new BeginTransactionCommand(baseRequest));
  const transactionId = begun.transactionId;

  try {
    const result = await work(transactionId);
    await client.send(
      new CommitTransactionCommand({ ...baseRequest, transactionId }),
    );
    return result;
  } catch (error) {
    try {
      await client.send(
        new RollbackTransactionCommand({ ...baseRequest, transactionId }),
      );
    } catch (rollbackError) {
      // 元Errorを消さず、Rollback失敗だけを別Logとして残す。
      console.error(
        JSON.stringify({
          event: "rollback_failed",
          name: rollbackError?.name,
          message: rollbackError?.message,
        }),
      );
    }
    throw error;
  }
}

// SQL Injectionを避けるNamed Parameter Helper。
export function stringParameter(name, value) {
  return { name, value: { stringValue: String(value) } };
}

// PostgreSQL UUID列へtextではなくUUID型として渡す。
export function uuidParameter(name, value) {
  return {
    name,
    value: { stringValue: String(value) },
    typeHint: "UUID",
  };
}

// 回数や金額等の整数Parameter。
export function longParameter(name, value) {
  return { name, value: { longValue: Number(value) } };
}

