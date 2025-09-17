import http from "k6/http";
import { sleep } from "k6";
import { check } from "k6";

export const options = {
  scenarios: {
    jwt_sqlite_light: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "10s", target: 5 }, // Ramp to 5 VUs
        { duration: "20s", target: 10 }, // Ramp to 10 VUs
        { duration: "20s", target: 10 }, // Hold at 10 VUs
        { duration: "10s", target: 0 }, // Ramp down
      ],
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<500"], // 95% under 500ms
    http_req_failed: ["rate<0.01"], // Error rate under 1%
  },
};

const BASE_URL = "http://localhost:8080";
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

  // 4. Remove from cart
  response = http.del(`${BASE_URL}/api/cart/remove/${randomItemId}`, null, {
    headers: headers(),
  });

  check(response, {
    "remove from cart status 200": (r) => r.status === 200,
  });

  // Longer pause for realistic usage
  sleep(0.5);
}

export function handleSummary(data) {
  const metrics = data.metrics;

  console.log(`
=== REALISTIC SQLite SHOPPING CART TEST RESULTS ===
Peak VUs: ${metrics.vus_max.values.max}
Total Requests: ${metrics.http_reqs.values.count}
Failed Requests: ${(metrics.http_req_failed.values.rate * 100).toFixed(2)}%
Requests/sec: ${metrics.http_reqs.values.rate.toFixed(1)} req/s
Avg Response Time: ${metrics.http_req_duration.values.avg.toFixed(2)}ms
95th Percentile: ${metrics.http_req_duration.values["p(95)"].toFixed(2)}ms

Architecture: Simple Random Session Tokens + SQLite Cart Storage
Note: SQLite is not designed for high concurrency - this test uses realistic load
`);
}
