import http from "k6/http";
import { check, sleep } from "k6";

const BASE_URL = __ENV.BASE_URL || "http://localhost:8080";
const ADMIN_KEY = __ENV.ADMIN_API_KEY || "dev-admin-key-change-me";
// ~1M users, limit=20 → max offset page ≈ 50000. Lower MAX_PAGE if DB is smaller.
const MAX_PAGE = parseInt(__ENV.MAX_PAGE || "50000", 10);
const MAX_AFTER_ID = parseInt(__ENV.MAX_AFTER_ID || "1000000", 10);
const DURATION = __ENV.DURATION || "30s";
const VUS = parseInt(__ENV.VUS || "10", 10);

export const options = {
  vus: VUS,
  duration: DURATION,
  thresholds: {
    http_req_failed: ["rate<0.05"],
    http_req_duration: ["p(95)<30000"],
  },
};

export default function () {
  const mode = __ITER % 3;
  let url;
  if (mode === 0) {
    const page = Math.floor(Math.random() * MAX_PAGE) + 1;
    url = `${BASE_URL}/api/v1/users?page=${page}&limit=20`;
  } else if (mode === 1) {
    url = `${BASE_URL}/api/v1/users?after_id=0&limit=20`;
  } else {
    const span = Math.max(1, MAX_AFTER_ID - 1000);
    const after = Math.floor(Math.random() * span) + 1000;
    url = `${BASE_URL}/api/v1/users?after_id=${after}&limit=20`;
  }
  const res = http.get(url, {
    headers: { "X-Admin-Key": ADMIN_KEY },
  });
  check(res, {
    "list status 200": (r) => r.status === 200,
  });
  sleep(0.1);
}
