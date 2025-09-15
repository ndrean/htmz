import http from "k6/http";
import { sleep } from "k6";

export const options = {
  scenarios: {
    constant_load: {
      executor: "constant-vus",
      vus: 1,
      duration: "10s",
    },
  },
};

export default function () {
  const sessionId = "slow-test-session";
  const headers = {
    'X-Session-Id': sessionId,
  };

  console.log("=== Starting slow test ===");

  // 1. Add item to cart
  console.log("1. Adding item...");
  let response = http.post("http://localhost:8080/api/cart/add/0", null, { headers });
  console.log(`Add result: ${response.status}`);

  // Wait 2 seconds between requests
  sleep(2);

  // 2. Try to increase quantity
  console.log("2. Increasing quantity...");
  response = http.post("http://localhost:8080/api/cart/increase-quantity/0", null, { headers });
  console.log(`Increase result: ${response.status}, body: ${response.body}`);

  // Wait 2 seconds
  sleep(2);

  console.log("=== Test complete ===");
}