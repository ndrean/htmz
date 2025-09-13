import http from "k6/http";
import { sleep } from "k6";

export const options = {
  vus: 50, // 50 virtual users (simulate 50 browsers)
  duration: "30s", // run for 30 seconds
};

export default function () {
  // 1. User loads TODO list
  http.get("http://localhost:8080/todos");

  // 2. User adds a TODO (HTMX POST)
  http.post(
    "http://localhost:8080/todos",
    JSON.stringify({
      title: "Test task",
    }),
    { headers: { "Content-Type": "application/json" } }
  );

  // 3. User deletes TODO id=1
  http.del("http://localhost:8080/todos/1");

  // 4. User goes to shopping list
  http.get("http://localhost:8080/shop");

  // 5. User views details for item 42
  http.get("http://localhost:8080/shop/items/42");

  // 6. User adds item 42 to cart
  http.post(
    "http://localhost:8080/cart",
    JSON.stringify({
      id: 42,
      quantity: 1,
    }),
    { headers: { "Content-Type": "application/json" } }
  );

  // Pause to simulate "thinking time"
  sleep(1);
}
