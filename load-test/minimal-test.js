import http from "k6/http";
import { sleep } from "k6";
import { check } from "k6";

export const options = {
  vus: 2, // Just 2 virtual users
  duration: "30s",
  thresholds: {
    http_req_duration: ["p(95)<1000"],
    http_req_failed: ["rate<0.05"], // 5% error tolerance
  },
};

const BASE_URL = "http://localhost:8080";
const itemIds = [0, 1, 2, 3];

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

    if (!jwtCookie) {
      console.error("Failed to get JWT cookie from server");
      return;
    }
  }

  const randomItemId = itemIds[Math.floor(Math.random() * itemIds.length)];

  const headers = () => ({
    Cookie: `jwt_token=${jwtCookie}`,
    "Content-Type": "application/json",
  });

  // Test simple add/remove cycle
  let response = http.post(`${BASE_URL}/api/cart/add/${randomItemId}`, null, {
    headers: headers(),
  });

  check(response, {
    "add to cart status 200": (r) => r.status === 200,
  });

  // Sleep between operations to reduce contention
  sleep(0.1);

  response = http.del(`${BASE_URL}/api/cart/remove/${randomItemId}`, null, {
    headers: headers(),
  });

  check(response, {
    "remove from cart status 200": (r) => r.status === 200,
  });

  // Longer pause
  sleep(1);
}

export function handleSummary(data) {
  const metrics = data.metrics;

  console.log(`
=== MINIMAL SQLite CART TEST RESULTS ===
VUs: ${metrics.vus_max.values.max}
Total Requests: ${metrics.http_reqs.values.count}
Failed Requests: ${(metrics.http_req_failed.values.rate * 100).toFixed(2)}%
Requests/sec: ${metrics.http_reqs.values.rate.toFixed(1)} req/s
Avg Response Time: ${metrics.http_req_duration.values.avg.toFixed(2)}ms
95th Percentile: ${metrics.http_req_duration.values["p(95)"].toFixed(2)}ms

This test validates basic functionality with minimal load.
`);
}