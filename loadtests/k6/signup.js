import http from "k6/http";
import { check, sleep } from "k6";

const BASE_URL = __ENV.BASE_URL || "http://localhost:8080";

export const options = {
  vus: 10,
  duration: "30s",
  thresholds: {
    http_req_failed: ["rate<0.05"],
    http_req_duration: ["p(95)<2000"],
  },
};

export default function () {
  const id = `${__VU}-${__ITER}-${Date.now()}`;
  const res = http.post(
    `${BASE_URL}/api/v1/signup`,
    JSON.stringify({
      email: `load-${id}@example.com`,
      password: "password123",
      display_name: "Load Test",
    }),
    { headers: { "Content-Type": "application/json" } }
  );
  check(res, {
    "signup status 201": (r) => r.status === 201,
  });
  sleep(0.1);
}
