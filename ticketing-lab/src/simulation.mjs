// 障害Simulation Modeは公開APIから指定させず、SSM Parameterから読む。
import { GetParameterCommand, SSMClient } from "@aws-sdk/client-ssm";
import { isSimulationMode } from "./workflow-domain.mjs";

const client = new SSMClient({});
const parameterName = process.env.SIMULATION_PARAMETER_NAME;

export async function getSimulationMode() {
  const result = await client.send(
    new GetParameterCommand({ Name: parameterName }),
  );
  const mode = result.Parameter?.Value;

  if (!isSimulationMode(mode)) {
    throw new Error(`Unsupported simulation mode: ${mode ?? "missing"}`);
  }

  return mode;
}

