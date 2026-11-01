import http from "k6/http";
import { check } from "k6";

// Script単体を直接実行されても、Phase 3以外へ負荷を送らない二段目のGuard。
if (__ENV.ALLOW_LOAD_TEST !== "phase3-owned-environment") {
  throw new Error("Set ALLOW_LOAD_TEST=phase3-owned-environment through the approved wrapper script.");
}

const targetPattern = /^http:\/\/sap-commerce-lab-phase3-[0-9]+\.ap-northeast-1\.elb\.amazonaws\.com\/?$/;
if (!targetPattern.test(__ENV.BASE_URL ?? "")) {
  throw new Error("BASE_URL must be the Tokyo ALB URL created for sap-commerce-lab-phase3.");
}

const baseUrl = __ENV.BASE_URL.replace(/\/$/, "");

export const options = {
  // Response JSONが商品配列であることも確認するためBodyを保持する。
  discardResponseBodies: false,
  scenarios: {
    scaling_profile: {
      // Responseが遅くなっても投入Rateを維持するOpen Model。
      executor: "ramping-arrival-rate",
      startRate: 1,
      timeUnit: "1s",
      preAllocatedVUs: 30,
      maxVUs: 100,
      gracefulStop: "30s",
      stages: [
        { target: 1, duration: "1m" },
        { target: 5, duration: "1s" },
        { target: 5, duration: "1m59s" },
        { target: 10, duration: "1s" },
        { target: 10, duration: "2m59s" },
        { target: 20, duration: "1s" },
        { target: 20, duration: "3m59s" },
        { target: 30, duration: "1s" },
        { target: 30, duration: "4m59s" },
      ],
    },
  },
  thresholds: {
    // 30秒の初期観察後、累積Error Rateが5%以上ならTestを中止する。
    http_req_failed: [{ threshold: "rate<0.05", abortOnFail: true, delayAbortEval: "30s" }],
    // 商品APIのp95が2秒以上なら、下流過負荷を広げないよう中止する。
    "http_req_duration{endpoint:products}": [
      { threshold: "p(95)<2000", abortOnFail: true, delayAbortEval: "30s" },
    ],
    checks: ["rate>0.95"],
  },
};

export default function () {
  const response = http.get(`${baseUrl}/api/products`, {
    tags: { endpoint: "products" },
    timeout: "5s",
  });

  let hasProductArray = false;
  if (response.status === 200) {
    try {
      const products = response.json();
      hasProductArray = Array.isArray(products) && products.length > 0;
    } catch {
      hasProductArray = false;
    }
  }

  check(response, {
    "products returns 200": (result) => result.status === 200,
    "products returns a non-empty array": () => hasProductArray,
  });
}
