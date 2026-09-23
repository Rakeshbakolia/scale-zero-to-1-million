import http from "k6/http";
import { check, sleep } from "k6";

const BASE_URL = __ENV.BASE_URL || "http://localhost:8080";
const ADMIN_KEY = __ENV.ADMIN_API_KEY || "dev-admin-key-change-me";

export const options = {
  vus: 15,
  duration: "1m",
};

export default function () {
  if (__ITER % 10 < 7) {
    const id = `${__VU}-${__ITER}-${Date.now()}`;
    const res = http.post(
      `${BASE_URL}/api/v1/signup`,
      JSON.stringify({
        email: `mixed-${id}@example.com`,
        password: "password123",
      }),
      { headers: { "Content-Type": "application/json" } }
    );
    check(res, { "signup ok": (r) => r.status === 201 || r.status === 409 });
  } else if (__ITER % 10 < 9) {
    const res = http.get(`${BASE_URL}/api/v1/users?page=1&limit=20`, {
      headers: { "X-Admin-Key": ADMIN_KEY },
    });
    check(res, { "list ok": (r) => r.status === 200 });
  } else {
    const res = http.get(`${BASE_URL}/health`);
    check(res, { "health ok": (r) => r.status === 200 });
  }
  sleep(0.05);
}
