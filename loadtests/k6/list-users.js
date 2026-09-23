import http from "k6/http";
import { check, sleep } from "k6";

const BASE_URL = __ENV.BASE_URL || "http://localhost:8080";
const ADMIN_KEY = __ENV.ADMIN_API_KEY || "dev-admin-key-change-me";

export const options = {
  vus: 10,
  duration: "30s",
  thresholds: {
    http_req_failed: ["rate<0.05"],
    http_req_duration: ["p(95)<2000"],
  },
};

export default function () {
  const page = ((__ITER % 5) + 1).toString();
  const res = http.get(`${BASE_URL}/api/v1/users?page=${page}&limit=20`, {
    headers: { "X-Admin-Key": ADMIN_KEY },
  });
  check(res, {
    "list status 200": (r) => r.status === 200,
  });
  sleep(0.1);
}
