import http from "k6/http";
import { sleep } from "k6";
import { check } from "k6";

export const options = {
  scenarios: {
    high_stress: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        // { duration: "10s", target: 5000 }, // Ramp to 5000 VUs (500 VUs/sec)
        { duration: "10s", target: 10_000 }, // Ramp to 10000 VUs (1000 VUs/sec)
        // { duration: "10s", target: 12000 }, // Ramp to 7500 VUs (250 VUs/sec)
        { duration: "30s", target: 12500 }, // Ramp to 10000 VUs (250 VUs/sec)
        // { duration: "10s", target: 12500 }, // Hold at 12500 VUs
        { duration: "10s", target: 0 }, // Ramp down
      ],
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<1000"], // 95% under 1s
    http_req_failed: ["rate<0.2"], // Error rate under 20%
  },
};

// Using item IDs instead of names (array indices from grocery_items.zig)
const itemIds = [
  0, // Apples
  1, // Bananas
  2, // Milk
  3, // Bread
  4, // Eggs
  5, // Chicken Breast
  6, // Rice
  7, // Pasta
];
/*
export default function () {
  // 1. User loads main page
  http.get("http://localhost:8080/api/items");
  sleep(0.01);
}
  */

export default function () {
  // Generate a unique session ID for this virtual user (VU)
  const sessionId = `k6-session-${__VU}-${Date.now()}-${Math.random()
    .toString(36)
    .substring(2, 11)}`;

  // Headers to include session ID in all requests
  const headers = {
    "X-Session-Id": sessionId,
  };

  const randomItemId = itemIds[Math.floor(Math.random() * itemIds.length)];

  // 1. Add item to cart (HTMX POST)
  let response = http.post(
    `http://localhost:8080/api/cart/add/${randomItemId}`,
    null,
    { headers }
  );
  check(response, {
    "add to cart status 200": (r) => r.status === 200,
  });

  // 2. Increase quantity (HTMX POST)
  response = http.post(
    `http://localhost:8080/api/cart/increase-quantity/${randomItemId}`,
    null,
    { headers }
  );
  check(response, {
    "increase quantity status 200": (r) => r.status === 200,
    "increase quantity returns number": (r) =>
      r.body && !isNaN(parseInt(r.body)),
  });

  // 3. Decrease quantity (HTMX POST)
  response = http.post(
    `http://localhost:8080/api/cart/decrease-quantity/${randomItemId}`,
    null,
    { headers }
  );
  check(response, {
    "decrease quantity status 200": (r) => r.status === 200,
  });

  // 4. Remove from cart (DELETE)
  response = http.del(
    `http://localhost:8080/api/cart/remove/${randomItemId}`,
    null,
    { headers }
  );
  check(response, {
    "remove from cart status 200": (r) => r.status === 200,
  });

  // Minimal pause for high throughput
  sleep(0.1);
}

export function handleSummary(data) {
  const metrics = data.metrics;
  // console.log(metrics);

  console.log(`
=== HIGH STRESS TEST RESULTS ===
Peak VUs: ${metrics.vus_max.values.max}
Total Requests: ${metrics.http_reqs.values.count}
Failed Requests: ${(metrics.http_req_failed.values.rate * 100).toFixed(2)}%
Requests/sec: ${metrics.http_reqs.values.rate.toFixed(1)} req/s
Avg Response Time: ${metrics.http_req_duration.values.avg.toFixed(2)}ms
95th Percentile: ${metrics.http_req_duration.values["p(95)"].toFixed(2)}ms

Status: ${
    metrics.http_req_failed.values.rate < 0.2 ? "✅ PASSED" : "❌ FAILED"
  } (error rate ${(metrics.http_req_failed.values.rate * 100).toFixed(2)}%)
Performance: ${
    metrics.http_req_duration.values["p(95)"] < 1000 ? "✅ GOOD" : "⚠️  SLOW"
  } (95% < 1000ms)
`);

  return { stdout: "" }; // Suppress default summary
}
