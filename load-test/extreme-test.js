import http from "k6/http";
import { sleep } from "k6";
import { check } from "k6";

export const options = {
  scenarios: {
    jwt_sqlite_extreme: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "30s", target: 1000 }, // Ramp to 1K users
        { duration: "30s", target: 2500 }, // Ramp to 2.5K users
        { duration: "30s", target: 5000 }, // Ramp to 5K users
        { duration: "60s", target: 5000 }, // Hold at 5K users
        { duration: "30s", target: 7500 }, // Ramp to 7.5K users
        { duration: "30s", target: 10000 }, // Ramp to 10K users
        { duration: "60s", target: 10000 }, // Hold at 10K users
        { duration: "30s", target: 15000 }, // Ramp to 15K users
        { duration: "60s", target: 15000 }, // Hold at 15K users
        { duration: "60s", target: 0 }, // Ramp down
      ],
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<2000"], // 95% under 2s (generous for extreme load)
    http_req_failed: ["rate<0.1"], // Error rate under 10% (expect some failures at extreme load)
  },
};

const BASE_URL = "http://localhost:8080";
const itemIds = [0, 1, 2, 3, 4, 5, 6, 7];

// Global JWT cookie for this VU
let jwtCookie = null;

export default function () {
  // Get a real JWT token from server if we don't have one
  if (!jwtCookie) {
    const response = http.get(`${BASE_URL}/`);
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

  const randomItemId = itemIds[Math.floor(Math.random() * itemIds.length)];

  // Headers with current JWT as cookie
  const headers = () => ({
    Cookie: `jwt_token=${jwtCookie}`,
    "Content-Type": "application/json",
  });

  // 1. Add item to cart
  let response = http.post(`${BASE_URL}/api/cart/add/${randomItemId}`, null, {
    headers: headers(),
    timeout: "10s", // Longer timeout for extreme load
  });

  check(response, {
    "add to cart status 200": (r) => r.status === 200,
  });

  // 2. Increase quantity
  response = http.post(
    `${BASE_URL}/api/cart/increase-quantity/${randomItemId}`,
    null,
    {
      headers: headers(),
      timeout: "10s",
    }
  );

  check(response, {
    "increase quantity status 200": (r) => r.status === 200,
    "increase quantity returns number": (r) =>
      r.body && !isNaN(parseInt(r.body)),
  });

  // 3. Remove from cart (simplified for extreme load)
  response = http.del(`${BASE_URL}/api/cart/remove/${randomItemId}`, null, {
    headers: headers(),
    timeout: "10s",
  });

  check(response, {
    "remove from cart status 200": (r) => r.status === 200,
  });

  // Very short pause for extreme throughput
  sleep(0.05);
}

export function handleSummary(data) {
  const metrics = data.metrics;

  console.log(`
=== EXTREME LOAD TEST: PER-USER SQLite DATABASES ===
Peak VUs: ${metrics.vus_max.values.max}
Total Requests: ${metrics.http_reqs.values.count}
Failed Requests: ${(metrics.http_req_failed.values.rate * 100).toFixed(2)}%
Requests/sec: ${metrics.http_reqs.values.rate.toFixed(1)} req/s
Avg Response Time: ${metrics.http_req_duration.values.avg.toFixed(2)}ms
95th Percentile: ${metrics.http_req_duration.values["p(95)"].toFixed(2)}ms

🚀 ARCHITECTURE: Per-User Temporary SQLite Databases
🔥 MAXIMUM SCALE TEST: Each user gets isolated database file
💪 CONCURRENCY: No database lock contention between users
`);
}