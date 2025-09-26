import http from "k6/http";
import { sleep } from "k6";
import { check } from "k6";
import { Trend, Counter } from "k6/metrics";
import exec from "k6/execution";

export const options = {
  scenarios: {
    progressive_load: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "10s", target: 5_000 }, // Ramp to 2K users
        { duration: "30s", target: 5_000 }, // Hold at 2K users (Plateau 1)
        { duration: "40s", target: 10_000 }, // Ramp to 6K users
        { duration: "30s", target: 10_000 }, // Hold at 6K users (Plateau 2)
        { duration: "10s", target: 0 }, // Ramp down
      ],
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<100"], // 95% under 100ms
  },
};

// const BASE_URL = __ENV.BASE_URL || "http://localhost:8880";
const BASE_URL = "http://91.98.129.192:8880";
// const BASE_URL = "http://localhost:8880";
const itemIds = [1, 2, 3, 4, 5, 6, 7];

// Custom metrics per plateau
const plateau5k = new Trend("http_req_duration_5k");
const plateau10k = new Trend("http_req_duration_10k");
const requests5k = new Counter("http_reqs_5k");
const requests10k = new Counter("http_reqs_10k");

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
  // Realistic user think time (1-5 seconds)
  // sleep(Math.random() * 4 + 1);
  sleep(0.2);

  // Determine current stage using k6 execution context elapsed time
  const elapsedMs = Date.now() - exec.scenario.startTime;
  const elapsedSeconds = elapsedMs / 1000;

  let currentStage = "none";
  // 10-40s: 5K plate
  // au (10s ramp + 30s hold)
  if (elapsedSeconds >= 10 && elapsedSeconds <= 40) currentStage = "plateau5k";
  // 50-80s: 10K plateau (after 10s ramp, 30s hold)
  if (elapsedSeconds >= 80 && elapsedSeconds <= 110)
    currentStage = "plateau10k";

  const randomItemId = itemIds[Math.floor(Math.random() * itemIds.length)];

  // Headers with current JWT as cookie + realistic browser headers for CF
  const headers = () => ({
    Cookie: `jwt_token=${jwtCookie}`,
    "Content-Type": "application/json",
    "User-Agent":
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    Accept:
      "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.5",
    "Accept-Encoding": "gzip, deflate, br",
    DNT: "1",
    Connection: "keep-alive",
    "Upgrade-Insecure-Requests": "1",
    "Sec-Fetch-Dest": "document",
    "Sec-Fetch-Mode": "navigate",
    "Sec-Fetch-Site": "none",
    "Cache-Control": "max-age=0",
  });

  // 1. Add item to cart
  let response = http.post(`${BASE_URL}/api/cart/add/${randomItemId}`, null, {
    headers: headers(),
    timeout: "30s",
    insecureSkipTLSVerify: true,
  });

  // Record metrics only during actual plateaus
  if (currentStage === "plateau5k") {
    plateau5k.add(response.timings.duration);
    requests5k.add(1);
  } else if (currentStage === "plateau10k") {
    plateau10k.add(response.timings.duration);
    requests10k.add(1);
  }
  // Ignore ramp periods ("none")

  check(response, {
    "add to cart status 200": (r) => r.status === 200,
  });
  // Realistic user interaction delay
  // sleep(Math.random() * 2 + 0.5);
  sleep(0.1);

  // 2. Remove from cart (simplified for extreme load)
  response = http.del(`${BASE_URL}/api/cart/remove/${randomItemId}`, null, {
    headers: headers(),
    timeout: "30s",
  });

  // Record metrics for remove request too
  if (currentStage === "plateau5k") {
    plateau5k.add(response.timings.duration);
    requests5k.add(1);
  } else if (currentStage === "plateau10k") {
    plateau10k.add(response.timings.duration);
    requests10k.add(1);
  }

  check(response, {
    "remove from cart status 200": (r) => r.status === 200,
  });

  // Final user delay before next action
  // sleep(Math.random() * 3 + 1);
  sleep(0.1);
}

export function handleSummary(data) {
  const metrics = data.metrics;

  // Calculate requests per second for each plateau
  const plateau5kReqs = metrics.http_reqs_5k?.values?.count || 0;
  const plateau10kReqs = metrics.http_reqs_10k?.values?.count || 0;

  // Plateau durations (30s each)
  const reqs5kPerSec = plateau5kReqs / 30;
  const reqs10kPerSec = plateau10kReqs / 30;

  console.log(`
=== PROGRESSIVE LOAD TEST: PLATEAU PERFORMANCE ===
📊 PLATEAU 1 (2K VUs - 30s):
  Requests: ${plateau5kReqs.toLocaleString()}
  Req/s: ${reqs5kPerSec.toFixed(0)}
  Avg Response Time: ${
    metrics.http_req_duration_5k?.values?.avg?.toFixed(2) || "N/A"
  }ms
  95th Percentile: ${
    metrics.http_req_duration_5k?.values?.["p(95)"]?.toFixed(2) || "N/A"
  }ms

📊 PLATEAU 2 (6K VUs - 30s):
  Requests: ${plateau10kReqs.toLocaleString()}
  Req/s: ${reqs10kPerSec.toFixed(0)}
  Avg Response Time: ${
    metrics.http_req_duration_10k?.values?.avg?.toFixed(2) || "N/A"
  }ms
  95th Percentile: ${
    metrics.http_req_duration_10k?.values?.["p(95)"]?.toFixed(2) || "N/A"
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
