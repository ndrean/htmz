import http from "k6/http";
import { check } from "k6";

export const options = {
  scenarios: {
    constant_load: {
      executor: "constant-vus",
      vus: 1,
      duration: "1s", // Just 1 second, 1 iteration
    },
  },
};

export default function () {
  const sessionId = "test-session-123";
  const headers = {
    'X-Session-Id': sessionId,
  };

  console.log("=== STARTING TEST ===");

  // 1. Add item to cart
  console.log("1. Adding item ID 0 to cart...");
  let response = http.post("http://localhost:8080/api/cart/add/0", null, { headers });
  console.log(`Add result: status=${response.status}, body='${response.body}'`);

  // 2. Try to increase quantity
  console.log("2. Increasing quantity for item ID 0...");
  response = http.post("http://localhost:8080/api/cart/increase-quantity/0", null, { headers });
  console.log(`Increase result: status=${response.status}, body='${response.body}'`);

  console.log("=== TEST COMPLETE ===");
}