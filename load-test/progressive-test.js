import http from "k6/http";
import { sleep } from "k6";
import { check } from "k6";
import { Trend, Counter } from "k6/metrics";

export const options = {
  scenarios: {
    progressive_load: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "10s", target: 4_000 }, // Ramp to 4K users
        { duration: "10s", target: 8_000 }, // Ramp to 8K users
        { duration: "10s", target: 10_000 }, // Ramp to 10K users
        { duration: "20s", target: 10_000 }, // Hold at 10K users

        { duration: "10s", target: 0 }, // Ramp down
      ],
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<5000"], // 95% under 5s
    http_req_failed: ["rate<0.2"], // Error rate under 20% (expect some failures at extreme load)
  },
};

const BASE_URL = "http://localhost:8080";
const itemIds = [1, 2, 3, 4, 5, 6, 7];

// Custom metrics per stage
const stage4k = new Trend('http_req_duration_4k');
const stage8k = new Trend('http_req_duration_8k');
const stage10k = new Trend('http_req_duration_10k');
const requests4k = new Counter('http_reqs_4k');
const requests8k = new Counter('http_reqs_8k');
const requests10k = new Counter('http_reqs_10k');

// Global JWT cookie for this VU
let jwtCookie = null;
let testStartTime = null;

export default function () {
  // Initialize test start time on first run
  if (!testStartTime) {
    testStartTime = Date.now();
  }

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

  // Determine current stage based on elapsed time
  const elapsed = Date.now() - testStartTime;
  let currentStage = 'ramp1'; // 0-10s: ramping to 4k
  if (elapsed > 10000 && elapsed <= 20000) currentStage = 'ramp2'; // 10-20s: ramping to 8k
  if (elapsed > 20000 && elapsed <= 30000) currentStage = 'ramp3'; // 20-30s: ramping to 10k
  if (elapsed > 30000 && elapsed <= 50000) currentStage = 'hold'; // 30-50s: holding at 10k

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

  // Record metrics based on current stage
  if (currentStage === 'ramp2') {
    stage8k.add(response.timings.duration);
    requests8k.add(1);
  } else if (currentStage === 'ramp3' || currentStage === 'hold') {
    stage10k.add(response.timings.duration);
    requests10k.add(1);
  } else {
    stage4k.add(response.timings.duration);
    requests4k.add(1);
  }

  check(response, {
    "add to cart status 200": (r) => r.status === 200,
  });
  sleep(0.1);

  // 2. Remove from cart (simplified for extreme load)
  response = http.del(`${BASE_URL}/api/cart/remove/${randomItemId}`, null, {
    headers: headers(),
    timeout: "30s",
  });

  // Record metrics for remove request too
  if (currentStage === 'ramp2') {
    stage8k.add(response.timings.duration);
    requests8k.add(1);
  } else if (currentStage === 'ramp3' || currentStage === 'hold') {
    stage10k.add(response.timings.duration);
    requests10k.add(1);
  } else {
    stage4k.add(response.timings.duration);
    requests4k.add(1);
  }

  check(response, {
    "remove from cart status 200": (r) => r.status === 200,
  });

  // Very short pause for maximum throughput
  sleep(0.1);
}

export function handleSummary(data) {
  const metrics = data.metrics;

  // Calculate requests per second for each stage (approximation)
  const stage4kReqs = metrics.http_reqs_4k?.values?.count || 0;
  const stage8kReqs = metrics.http_reqs_8k?.values?.count || 0;
  const stage10kReqs = metrics.http_reqs_10k?.values?.count || 0;

  const reqs4kPerSec = stage4kReqs / 10; // 10s ramp period
  const reqs8kPerSec = stage8kReqs / 10; // 10s ramp period
  const reqs10kPerSec = stage10kReqs / 30; // 10s ramp + 20s hold = 30s

  console.log(`
=== PROGRESSIVE LOAD TEST: PER-STAGE BREAKDOWN ===
📊 STAGE PERFORMANCE:
  4K VUs Stage: ${stage4kReqs.toLocaleString()} requests (${reqs4kPerSec.toFixed(0)} req/s)
  8K VUs Stage: ${stage8kReqs.toLocaleString()} requests (${reqs8kPerSec.toFixed(0)} req/s)
  10K VUs Stage: ${stage10kReqs.toLocaleString()} requests (${reqs10kPerSec.toFixed(0)} req/s)

📈 RESPONSE TIMES:
  4K VUs: ${metrics.http_req_duration_4k?.values?.avg?.toFixed(2) || 'N/A'}ms avg
  8K VUs: ${metrics.http_req_duration_8k?.values?.avg?.toFixed(2) || 'N/A'}ms avg
  10K VUs: ${metrics.http_req_duration_10k?.values?.avg?.toFixed(2) || 'N/A'}ms avg

=== OVERALL RESULTS ===
Peak VUs: ${metrics.vus_max.values.max}
Total Requests: ${metrics.http_reqs.values.count}
Failed Requests: ${(metrics.http_req_failed.values.rate * 100).toFixed(2)}%
Overall Requests/sec: ${metrics.http_reqs.values.rate.toFixed(1)} req/s
Avg Response Time: ${metrics.http_req_duration.values.avg.toFixed(2)}ms
95th Percentile: ${metrics.http_req_duration.values["p(95)"].toFixed(2)}ms

🎯 MAXIMUM SCALE REACHED: ${metrics.vus_max.values.max} concurrent users
`);
}
