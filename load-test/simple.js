import http from "k6/http";
import { sleep } from "k6";
import { check } from "k6";
export const options = {
  scenarios: {
    jwt_sqlite_stress: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "5s", target: 10 }, // Ramp to 10 VUs
        { duration: "10s", target: 50 }, // Ramp to 50 VUs
        { duration: "30s", target: 100 }, // Ramp to 100 VUs
        { duration: "5s", target: 0 }, // Ramp down
      ],
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<1000"], // 95% under 1s
    http_req_failed: ["rate<0.05"], // Error rate under 5% (more realistic for SQLite)
  },
};

// const BASE_URL = "http://91.98.129.192:8080"; // JWT + SQLite server
const itemIds = [1, 2, 3, 4, 5, 6, 7];

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

  // Use server-generated JWT token for all requests

  // Headers with current JWT as cookie
  const headers = () => ({
    Cookie: `jwt_token=${jwtCookie}`,
    "Content-Type": "application/json",
  });

  // 1. Add item to cart
  let response = http.post(`${BASE_URL}/api/cart/add/${randomItemId}`, null, {
    headers: headers(),
  });

  check(response, {
    "add to cart status 200": (r) => r.status === 200,
  });

  // 2. Increase quantity
  response = http.post(
    `${BASE_URL}/api/cart/increase-quantity/${randomItemId}`,
    null,
    { headers: headers() }
  );

  check(response, {
    "increase quantity status 200": (r) => r.status === 200,
    "increase quantity returns number": (r) =>
      r.body && !isNaN(parseInt(r.body)),
  });

  // 3. Decrease quantity
  response = http.post(
    `${BASE_URL}/api/cart/decrease-quantity/${randomItemId}`,
    null,
    { headers: headers() }
  );

  check(response, {
    "decrease quantity status 200": (r) => r.status === 200,
  });
  sleep(0.1);

  // 4. Remove from cart
  response = http.del(`${BASE_URL}/api/cart/remove/${randomItemId}`, null, {
    headers: headers(),
  });

  check(response, {
    "remove from cart status 200": (r) => r.status === 200,
  });

  // Minimal pause for high throughput
  sleep(0.2);
}

export function handleSummary(data) {
  const metrics = data.metrics;

  console.log(`
=== SIMPLIFIED SESSION + SQLite SHOPPING CART STRESS TEST RESULTS ===
Peak VUs: ${metrics.vus_max.values.max}
Total Requests: ${metrics.http_reqs.values.count}
Failed Requests: ${(metrics.http_req_failed.values.rate * 100).toFixed(2)}%
Requests/sec: ${metrics.http_reqs.values.rate.toFixed(1)} req/s
Avg Response Time: ${metrics.http_req_duration.values.avg.toFixed(2)}ms
95th Percentile: ${metrics.http_req_duration.values["p(95)"].toFixed(2)}ms

Architecture: Simple Random Session Tokens + SQLite Cart Storage
`);

  // return { stdout: "" }; // Suppress default summary
}
