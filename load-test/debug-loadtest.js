import http from "k6/http";
import { sleep } from "k6";
import { check } from "k6";

export const options = {
  scenarios: {
    constant_load: {
      executor: "constant-vus",
      vus: 1, // Test with single user to isolate session bugs
      duration: "30s",
    },
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
  const sessionId = `k6-session-${__VU}-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;

  // Headers to include session ID in all requests
  const headers = {
    'X-Session-Id': sessionId,
  };

  // 1. User loads main page
  let response = http.get("http://localhost:8080/", { headers });
  let success = check(response, {
    "main page status 200": (r) => r.status === 200,
  });
  if (!success) {
    console.error(`Main page failed: ${response.status} - ${response.body}`);
  }

  // 2. User navigates to grocery list (HTMX request)
  response = http.get("http://localhost:8080/groceries", { headers });
  success = check(response, {
    "groceries page status 200": (r) => r.status === 200,
  });
  if (!success) {
    console.error(`Groceries page failed: ${response.status} - ${response.body}`);
  }

  // 5. User clicks on a random grocery item to see details
  const randomItemId = itemIds[Math.floor(Math.random() * itemIds.length)];

  // 6. User adds item to cart (HTMX POST)
  response = http.post(`http://localhost:8080/api/cart/add/${randomItemId}`, null, { headers });
  success = check(response, {
    "add to cart status 200": (r) => r.status === 200,
  });
  if (!success) {
    console.error(`Add to cart failed for item ID ${randomItemId}: ${response.status} - ${response.body}`);
  }

  // 7. User navigates to shopping list
  response = http.get("http://localhost:8080/shopping-list", { headers });
  success = check(response, {
    "shopping list status 200": (r) => r.status === 200,
  });
  if (!success) {
    console.error(`Shopping list failed: ${response.status} - ${response.body}`);
  }

  // 9. User increases quantity of an item
  response = http.post(`http://localhost:8080/api/cart/increase-quantity/${randomItemId}`, null, { headers });
  success = check(response, {
    "increase quantity status 200": (r) => r.status === 200,
  });
  if (!success) {
    console.error(`Increase quantity failed for item ID ${randomItemId}: ${response.status} - ${response.body}`);
  }

  // 10. User decreases quantity
  response = http.post(`http://localhost:8080/api/cart/decrease-quantity/${randomItemId}`, null, { headers });
  success = check(response, {
    "decrease quantity status 200": (r) => r.status === 200,
  });
  if (!success) {
    console.error(`Decrease quantity failed for item ID ${randomItemId}: ${response.status} - ${response.body}`);
  }

  // 11. User removes item from cart
  response = http.del(`http://localhost:8080/api/cart/remove/${randomItemId}`, null, { headers });
  success = check(response, {
    "remove from cart status 200": (r) => r.status === 200,
  });
  if (!success) {
    console.error(`Remove from cart failed for item ID ${randomItemId}: ${response.status} - ${response.body}`);
  }

  // Pause to simulate "thinking time"
  sleep(Math.random() * 2 + 0.5); // Random 0.5-2.5s pause
}