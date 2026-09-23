import http from "k6/http";
import { check, sleep } from "k6";

const BASE_URL = __ENV.BASE_URL || "http://localhost:8080";

// Ramp until failure rate rises — find rough local ceiling
export const options = {
  scenarios: {
    ramp_signup: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "15s", target: 10 },
        { duration: "15s", target: 25 },
        { duration: "15s", target: 50 },
        { duration: "15s", target: 75 },
        { duration: "15s", target: 100 },
        { duration: "10s", target: 0 },
      ],
      gracefulRampDown: "5s",
    },
  },
  thresholds: {
    http_req_failed: [{ threshold: "rate<0.15", abortOnFail: false }],
  },
};

export default function () {
  const id = `${__VU}-${__ITER}-${Date.now()}`;
  const res = http.post(
    `${BASE_URL}/api/v1/signup`,
    JSON.stringify({
      email: `stress-${id}@example.com`,
      password: "password123",
    }),
    { headers: { "Content-Type": "application/json" }, timeout: "10s" }
  );
  check(res, {
    "signup 201": (r) => r.status === 201,
  });
  sleep(0.02);
}
