import http from "k6/http";
import { sleep } from "k6";

export const options = {
  vus: 6000, // Same as original test
  duration: "30s",
};

const items = [
  "Apples",
  "Bananas",
  "Milk",
  "Bread",
  "Eggs",
  "Chicken Breast",
  "Rice",
  "Pasta",
];

export default function () {
  // 1. User loads main page
  http.get("http://localhost:8080/");

  // 2. User navigates to grocery list (HTMX request)
  http.get("http://localhost:8080/groceries");

  // 3. Load grocery items list (HTMX auto-triggered)
  http.get("http://localhost:8080/api/items");

  // 4. Load default item details (HTMX auto-triggered)
  http.get("http://localhost:8080/item-details/default");

  // 5. User clicks on a random grocery item to see details
  const randomItem = items[Math.floor(Math.random() * items.length)];
  http.get(`http://localhost:8080/api/item-details/${randomItem}`);

  // 6. User adds item to cart (HTMX POST)
  http.post(`http://localhost:8080/api/cart/add/${randomItem}`);

  // 7. User navigates to shopping list
  http.get("http://localhost:8080/shopping-list");

  // 8. Load cart items (HTMX auto-triggered)
  http.get("http://localhost:8080/api/cart");

  // 9. User increases quantity - OPTIMIZED (returns just the number!)
  http.post(`http://localhost:8080/api/cart/increase-quantity/${randomItem}`);

  // 10. User decreases quantity - OPTIMIZED (returns just the number!)
  http.post(`http://localhost:8080/api/cart/decrease-quantity/${randomItem}`);

  // 11. User removes item from cart (still uses full refresh)
  http.del(`http://localhost:8080/api/cart/remove/${randomItem}`);

  // Pause to simulate "thinking time"
  sleep(Math.random() * 2 + 0.5); // Random 0.5-2.5s pause
}