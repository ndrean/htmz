import http from "k6/http";
import { sleep } from "k6";
import { check } from "k6";

export const options = {
  scenarios: {
    stress_test: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "30s", target: 50 },   // Ramp up to 50 users over 30s
        { duration: "1m", target: 100 },   // Ramp up to 100 users over 1m
        { duration: "1m", target: 200 },   // Ramp up to 200 users over 1m
        { duration: "1m", target: 500 },   // Ramp up to 500 users over 1m
        { duration: "1m", target: 1000 },  // Ramp up to 1000 users over 1m
        { duration: "2m", target: 1000 },  // Stay at 1000 users for 2m
        { duration: "1m", target: 0 },     // Ramp down to 0 users over 1m
      ],
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<500"], // 95% of requests must complete under 500ms
    http_req_failed: ["rate<0.1"],    // Error rate must be under 10%
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

export default function () {
  // Generate a unique session ID for this virtual user (VU)
  const sessionId = `stress-session-${__VU}-${__ITER}-${Math.random().toString(36).substr(2, 9)}`;

  // Headers to include session ID in all requests
  const headers = {
    'X-Session-Id': sessionId,
  };

  // Pick a random item for this user session
  const randomItemId = itemIds[Math.floor(Math.random() * itemIds.length)];

  // 1. Add item to cart (HTMX POST)
  let response = http.post(`http://localhost:8080/api/cart/add/${randomItemId}`, null, { headers });
  check(response, {
    "add to cart status 200": (r) => r.status === 200,
  });

  // Small pause to simulate user thinking
  sleep(Math.random() * 0.5 + 0.1); // 0.1-0.6s pause

  // 2. Increase quantity (HTMX POST)
  response = http.post(`http://localhost:8080/api/cart/increase-quantity/${randomItemId}`, null, { headers });
  check(response, {
    "increase quantity status 200": (r) => r.status === 200,
    "increase quantity returns number": (r) => r.body && !isNaN(parseInt(r.body)),
  });

  // Small pause
  sleep(Math.random() * 0.5 + 0.1);

  // 3. Decrease quantity (HTMX POST)
  response = http.post(`http://localhost:8080/api/cart/decrease-quantity/${randomItemId}`, null, { headers });
  check(response, {
    "decrease quantity status 200": (r) => r.status === 200,
  });

  // Small pause
  sleep(Math.random() * 0.3 + 0.1);

  // 4. Remove from cart (DELETE)
  response = http.del(`http://localhost:8080/api/cart/remove/${randomItemId}`, null, { headers });
  check(response, {
    "remove from cart status 200": (r) => r.status === 200,
  });

  // Simulate user thinking time between full sessions
  sleep(Math.random() * 1 + 0.5); // 0.5-1.5s pause
}

export function handleSummary(data) {
  return {
    'stdout': textSummary(data, { indent: ' ', enableColors: true }),
  };
}

function textSummary(data, options) {
  const indent = options.indent || '';
  const enableColors = options.enableColors || false;

  let summary = `
${indent}✓ Stress Test Results:
${indent}  Peak VUs: ${data.metrics.vus_max.values.max}
${indent}  Total Requests: ${data.metrics.http_reqs.values.count}
${indent}  Failed Requests: ${(data.metrics.http_req_failed.values.rate * 100).toFixed(2)}%
${indent}  Average Response Time: ${data.metrics.http_req_duration.values.avg.toFixed(2)}ms
${indent}  95th Percentile Response Time: ${data.metrics.http_req_duration.values['p(95)'].toFixed(2)}ms
${indent}  Requests per Second: ${data.metrics.http_reqs.values.rate.toFixed(2)}
`;

  if (data.metrics.http_req_failed.values.rate > 0.1) {
    summary += `${indent}  ⚠️  ERROR RATE TOO HIGH: ${(data.metrics.http_req_failed.values.rate * 100).toFixed(2)}% (threshold: <10%)\n`;
  } else {
    summary += `${indent}  ✅ Error rate within acceptable limits\n`;
  }

  if (data.metrics.http_req_duration.values['p(95)'] > 500) {
    summary += `${indent}  ⚠️  RESPONSE TIME TOO HIGH: ${data.metrics.http_req_duration.values['p(95)'].toFixed(2)}ms (threshold: <500ms)\n`;
  } else {
    summary += `${indent}  ✅ Response times within acceptable limits\n`;
  }

  return summary;
}