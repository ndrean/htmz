import http from "k6/http";
import { sleep } from "k6";
import { check } from "k6";
import { Trend, Counter } from "k6/metrics";
import exec from "k6/execution";

export const options = {
  scenarios: {
    caddy_load: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "20s", target: 5000 }, // Ramp to 5K users
        { duration: "20s", target: 5000 }, // Hold at 5K users
        { duration: "10s", target: 0 }, // Ramp down
      ],
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<150"], // 95% under 150ms
  },
};

const BASE_URL = __ENV.BASE_URL || "http://localhost:8080";
const itemIds = [1, 2, 3, 4, 5, 6, 7];

// Custom metrics for 5K plateau
const plateau5k = new Trend("http_req_duration_5k");
const requests5k = new Counter("http_reqs_5k");

// Global JWT cookie for this VU
let jwtCookie = null;

export default function () {
  // Get a real JWT token from server if we don't have one
  if (!jwtCookie) {
    const response = http.get(`${BASE_URL}/`, { timeout: "30s" });
    const cookieHeader = response.headers["Set-Cookie"];
    if (cookieHeader) {
      const match = cookieHeader.match(/jwt_token=([^;]+)/);
      if (match) {
        jwtCookie = match[1];
      }
    }

    // If still no cookie, something is wrong
    if (!jwtCookie) {
      console.error("Failed to get JWT cookie from server");
      return;
    }
  }
  sleep(0.1);

  // Determine current stage using k6 execution context elapsed time
  const elapsedMs = Date.now() - exec.scenario.startTime;
  const elapsedSeconds = elapsedMs / 1000;

  let currentStage = "none";
  // 20-40s: 5K plateau (20s ramp + 20s hold)
  if (elapsedSeconds >= 20 && elapsedSeconds <= 40) currentStage = "plateau5k";

  const randomItemId = itemIds[Math.floor(Math.random() * itemIds.length)];

  // Headers with current JWT as cookie
  const headers = () => ({
    Cookie: `jwt_token=${jwtCookie}`,
    "Content-Type": "application/json",
  });

  // 1. Add item to cart
  let response = http.post(`${BASE_URL}/api/cart/add/${randomItemId}`, null, {
    headers: headers(),
    timeout: "30s",
  });

  // Record metrics only during actual plateau
  if (currentStage === "plateau5k") {
    plateau5k.add(response.timings.duration);
    requests5k.add(1);
  }

  check(response, {
    "add to cart status 200": (r) => r.status === 200,
  });
  sleep(0.1);

  // 2. Remove from cart
  response = http.del(`${BASE_URL}/api/cart/remove/${randomItemId}`, null, {
    headers: headers(),
    timeout: "30s",
  });

  // Record metrics for remove request too
  if (currentStage === "plateau5k") {
    plateau5k.add(response.timings.duration);
    requests5k.add(1);
  }

  check(response, {
    "remove from cart status 200": (r) => r.status === 200,
  });

  sleep(0.1);
}

export function handleSummary(data) {
  const metrics = data.metrics;

  // Calculate requests per second for 5K plateau
  const plateau5kReqs = metrics.http_reqs_5k?.values?.count || 0;

  // Plateau duration (20s)
  const reqs5kPerSec = plateau5kReqs / 20;

  console.log(`
=== CADDY LOAD TEST: 5K VUs PERFORMANCE ===
📊 PLATEAU (5K VUs - 20s):
  Requests: ${plateau5kReqs.toLocaleString()}
  Req/s: ${reqs5kPerSec.toFixed(0)}
  Avg Response Time: ${
    metrics.http_req_duration_5k?.values?.avg?.toFixed(2) || "N/A"
  }ms
  95th Percentile: ${
    metrics.http_req_duration_5k?.values?.["p(95)"]?.toFixed(2) || "N/A"
  }ms

=== OVERALL RESULTS ===
Peak VUs: ${metrics.vus_max.values.max}
Total Requests: ${metrics.http_reqs.values.count}
Failed Requests: ${(metrics.http_req_failed.values.rate * 100).toFixed(2)}%
Overall Requests/sec: ${metrics.http_reqs.values.rate.toFixed(1)} req/s
Avg Response Time: ${metrics.http_req_duration.values.avg.toFixed(2)}ms
95th Percentile: ${metrics.http_req_duration.values["p(95)"].toFixed(2)}ms
`);
}
